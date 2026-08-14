# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # Model catalog, offering construction, and capability derivation helpers.
          module ModelCatalogHelpers
            def offering_for(model:, model_family: nil, instance_id: nil, **metadata)
              model_id_val = self.class.resolve_model_id(model)
              build_offering(
                model: model_id_val,
                alias_name: alias_for(model_id_val),
                model_family: model_family || model_family_for(model_id_val),
                instance_id: instance_id,
                usage_type: metadata.delete(:usage_type) || usage_type_for(model_id_val),
                metadata: metadata
              )
            end

            def health(live: false)
              baseline = {
                provider: :bedrock,
                region: region,
                configured: true,
                ready: true,
                live: live,
                credentials: credential_source
              }
              unless live
                log.debug { "bedrock.provider.health: offline check (region=#{region})" }
                return baseline.merge(checked: false)
              end

              log.info { "bedrock.provider.health: live check (region=#{region})" }
              bedrock_client.list_foundation_models
              log.info { 'bedrock.provider.health: live check passed' }
              baseline.merge(checked: true)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'bedrock.provider.health')
              baseline.merge(checked: true, ready: false, error: e.class.name, message: e.message)
            end

            def readiness(live: false)
              log.debug { "bedrock.provider.readiness: checking (live=#{live})" }
              health(live: live).merge(local: false, remote: true, api_base: api_base,
                                       endpoints: endpoint_manifest)
            end

            def list_models(**filters)
              request_filters = {}
              request_filters[:by_provider] = filters[:by_provider] if filters[:by_provider]

              log.info { 'bedrock.provider.list_models: fetching live model list' }
              response = bedrock_client.list_foundation_models(**request_filters)
              models = Array(value(response, :model_summaries)).filter_map { |s| model_info_from_summary(s) }
              log.info { "bedrock.provider.list_models: found #{models.size} models" }
              models
            end

            def discover_offerings(live: false, **filters)
              return static_offerings(**filters) unless live

              provider_health = health(live:)
              @cached_offerings = discover_live_offerings(filters, provider_health, live:)
              log_discover_complete(@cached_offerings)
              @cached_offerings
            end

            def discovery_registry_readiness(provider_health, live:)
              {
                provider: slug.to_sym,
                configured: configured?,
                ready: provider_health[:ready] == true,
                live: live,
                health: provider_health
              }
            end

            def discover_live_offerings(filters, provider_health, live:)
              discovery_registry_readiness(provider_health, live:)
              Array(list_models(live:, **filters)).filter_map do |model|
                next unless model_matches_filters?(model, filters)
                next unless model_allowed?(model.id)

                log_model_discovered(model)
                offering_from_model(model, health: provider_health)
              end
            end

            def log_model_discovered(model)
              log.debug(
                "[#{slug}] instance=#{provider_instance_id} action=model_discovered " \
                "model=#{model.id} family=#{model.family}"
              )
            end

            def log_discover_complete(offerings)
              log.info(
                "[#{slug}] instance=#{provider_instance_id} action=discover_complete " \
                "model_count=#{Array(offerings).size}"
              )
            end

            private

            def offering_from_model(model_info, health: {})
              model = model_info.respond_to?(:id) ? model_info.id : model_info
              real = if model_info.respond_to?(:capabilities)
                       Array(model_info.capabilities).to_h do |cap|
                         [cap.to_s.downcase.tr('-', '_').tr(' ', '_').to_sym, true]
                       end
                     else
                       {}
                     end
              metadata = model_info.respond_to?(:metadata) && model_info.metadata.is_a?(Hash) ? model_info.metadata : {}
              policy = Legion::Extensions::Llm::CapabilityPolicy.resolve(
                real: real,
                provider_catalog: catalog_capabilities(model),
                probe: {},
                provider_envelope: provider_envelope_capabilities,
                provider_config: provider_capability_config,
                instance_config: instance_capability_config,
                model_config: model_capability_config(model)
              )

              build_offering(
                model: model,
                alias_name: alias_for(model),
                model_family: model_info.respond_to?(:family) ? model_info.family : model_family_for(model),
                usage_type: model_info.respond_to?(:embedding?) && model_info.embedding? ? :embedding : :inference,
                capabilities: policy[:capabilities],
                capability_sources: policy[:sources],
                metadata: metadata,
                health: health
              )
            end

            def model_info_from_summary(summary)
              model = value(summary, :model_id)
              input_mods = Array(value(summary, :input_modalities)).map { |m| m.to_s.downcase }
              output_mods = Array(value(summary, :output_modalities)).map { |m| m.to_s.downcase }

              Legion::Extensions::Llm::Model::Info.new(
                id: model,
                name: alias_for(model) || model,
                provider: :bedrock,
                family: (normalize_provider(value(summary, :provider_name)) || model_family_for(model)).to_s,
                capabilities: capabilities_from_modalities(input_mods, output_mods, summary),
                modalities_input: input_mods,
                modalities_output: output_mods,
                metadata: normalize_response(summary)
              )
            end

            def offering_from_summary(summary, health: {})
              offering_from_model(model_info_from_summary(summary), health:)
            end

            def build_offering(model:, model_family:, usage_type:, instance_id: nil, alias_name: nil,
                               capabilities: nil, capability_sources: nil, metadata: {}, health: {})
              limits = infer_limits(model)
              normalized_family = model_family&.to_sym
              Legion::Extensions::Llm::Routing::ModelOffering.new(
                provider_family: :bedrock,
                instance_id: instance_id,
                transport: offering_transport,
                tier: offering_tier,
                model: model,
                usage_type: usage_type,
                capabilities: capabilities || default_capabilities(model),
                capability_sources: capability_sources,
                limits: limits,
                health: health,
                metadata: metadata.merge(model_family: normalized_family, alias: alias_name).compact
              )
            end

            def infer_limits(model)
              detail = model_detail(model.to_s)
              return detail if detail.is_a?(Hash) && detail[:context_window]

              ctx = CONTEXT_WINDOWS.find { |prefix, _| model.to_s.start_with?(prefix) }&.last
              ctx ? { context_window: ctx } : {}
            end

            def fetch_model_detail(model_name)
              ctx = CONTEXT_WINDOWS.find { |prefix, _| model_name.start_with?(prefix) }&.last
              ctx ? { context_window: ctx } : nil
            end

            def static_offerings(**filters)
              STATIC_MODELS.filter_map do |entry|
                provider_filter = normalize_provider(filters[:by_provider])
                next if provider_filter && model_family_for(entry.fetch(:model)) != provider_filter

                offering_for(**entry.slice(:model, :usage_type))
              end
            end

            def capabilities_from_summary(summary)
              capabilities = []
              capabilities << :embedding if usage_type_from_modalities(value(summary, :output_modalities)) == :embedding
              capabilities << :chat if capabilities.empty?
              capabilities << :streaming if value(summary, :response_streaming_supported)
              capabilities << :vision if Array(value(summary, :input_modalities)).map(&:to_s).include?('IMAGE')
              capabilities
            end

            def capabilities_from_modalities(input_mods, output_mods, summary)
              caps = []
              caps << :embedding if output_mods.include?('embedding')
              unless caps.include?(:embedding)
                caps << :completion
                caps << :streaming if value(summary, :response_streaming_supported)
              end
              caps << :vision if input_mods.include?('image')
              caps
            end

            def real_capabilities_from_summary(summary)
              caps = {}
              caps[:streaming] = true if value(summary, :response_streaming_supported)
              input_mods = Array(value(summary, :input_modalities)).map { |m| m.to_s.upcase }
              caps[:vision] = true if input_mods.include?('IMAGE')
              output_mods = Array(value(summary, :output_modalities)).map { |m| m.to_s.upcase }
              caps[:embedding] = true if output_mods.include?('EMBEDDING')
              caps
            end

            def provider_envelope_capabilities
              { tools: true }
            end

            def catalog_capabilities(model)
              info = Legion::Extensions::Llm::Models.find(model.to_s, :bedrock)
              caps = Legion::Extensions::Llm::Capabilities.normalize(info.capabilities)
              caps.to_h { |cap| [cap, true] }
            rescue Legion::Extensions::Llm::ModelNotFoundError
              {}
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'bedrock.provider.catalog_capabilities')
              {}
            end

            def model_family_for(model)
              normalize_provider(model.to_s.split('.').first)
            end

            def normalize_provider(provider)
              val = provider.to_s.downcase.tr(' ', '_').tr('-', '_')
              return nil if val.empty?

              case val
              when 'mistral_ai' then :mistral
              else val.to_sym
              end
            end

            def titan_embed?(model)
              model.to_s.include?('titan-embed')
            end

            def alias_for(model)
              ALIASES.key(model)
            end

            def usage_type_for(model)
              titan_embed?(model) ? :embedding : :inference
            end

            def usage_type_from_modalities(output_modalities)
              Array(output_modalities).map(&:to_s).include?('EMBEDDING') ? :embedding : :inference
            end

            def default_capabilities(model)
              return %i[embedding] if titan_embed?(model)

              caps = %i[chat streaming]
              caps << :vision if Capabilities.vision?(model)
              caps << :functions if Capabilities.functions?(model)
              caps
            end

            def model_id(model)
              id = model.respond_to?(:id) ? model.id : model
              self.class.resolve_model_id(id)
            end

            def model_max_tokens(model)
              model.respond_to?(:max_tokens) ? model.max_tokens : nil
            end
          end
        end
      end
    end
  end
end
