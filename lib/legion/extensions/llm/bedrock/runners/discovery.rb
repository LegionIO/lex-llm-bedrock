# frozen_string_literal: true

require 'digest'
require 'time'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/bedrock/helpers/callable'
require 'legion/extensions/llm/bedrock/provider'
require 'legion/extensions/llm/bedrock/instance_identity'
require 'legion/extensions/llm/bedrock/thinking_modes'

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Runners
          # Bedrock discovery runner: ONLY the Bedrock-specific work. The
          # generic reconcile / claim / activate / probe (cadence + reactive) /
          # replace / weight-publication / health-display pipeline is mixed in
          # from the shared Discovery::Pipeline. Weight is NOT computed here —
          # the shared WeightReconciler recomputes it from live settings at
          # publish.
          #
          # The catalog is NOT OpenAI-shaped: it is the AWS control-plane
          # ListFoundationModels call (SDK client, not HTTP), and readiness is
          # the same non-inference control-plane call. fetch_raw_models /
          # model_id_from / check_health are therefore overridden entirely.
          # The secondary physical id is the derived region/credential id
          # (dedup/diagnostics only — never identity: the instance identity is
          # the operator's config name), and the offering-draft evidence is
          # the Bedrock catalog knowledge.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            # ── Catalog (AWS control plane, not HTTP) ─────────────────────────
            def fetch_raw_models(instance_cfg:)
              client = build_bedrock_client(instance_cfg: instance_cfg)
              response = client.list_foundation_models
              response.respond_to?(:model_summaries) ? Array(response.model_summaries) : []
            rescue NameError, NoMethodError, ArgumentError
              # Programming errors must fail loud — swallowing them here would
              # publish zero offerings for every instance (invisible).
              raise
            rescue StandardError => e
              # B8: a failed control-plane observation is NOT an empty
              # catalog — CatalogFetchFailure means "no observation"; the
              # pipeline keeps the last published snapshot and the next tick
              # retries. A genuine empty catalog arrives as [] and still
              # publishes.
              handle_exception(e, level: :warn, handled: false,
                                  operation: 'bedrock.runner.discovery.fetch_raw_models')
              raise CatalogFetchFailure, "Bedrock ListFoundationModels failed (#{e.class.name})", cause: e
            end

            # ListFoundationModels summaries carry the model id on :model_id
            # (SDK Struct shape or Hash).
            def model_id_from(model_data)
              if model_data.respond_to?(:model_id)
                model_data.model_id.to_s
              elsif model_data.is_a?(Hash)
                (model_data[:model_id] || model_data['model_id']).to_s
              else
                ''
              end
            end

            # Readiness is the same non-inference control-plane call as the
            # catalog (ListFoundationModels) — Bedrock has no HTTP /health.
            def check_health(instance_cfg:)
              client = build_bedrock_client(instance_cfg: instance_cfg)
              client.list_foundation_models
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: true,
                reason: 'Bedrock ListFoundationModels succeeded',
                metadata: {
                  region: Legion::Extensions::Llm::Bedrock::InstanceIdentity.resolve_region(instance_cfg: instance_cfg)
                }
              )
            rescue NameError, NoMethodError, ArgumentError
              # Programming errors must fail loud — a swallowed one would leave
              # the instance stuck in :initializing with no actionable signal.
              raise
            rescue Aws::Bedrock::Errors::ServiceError => e
              readiness_failure(operation: 'ListFoundationModels', error: e)
            rescue StandardError => e
              readiness_failure(operation: 'health check', error: e)
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Bedrock::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Secondary physical id (dedup/diagnostics only) ────────────────
            # The derived region/credential id — never identity: the instance
            # identity is the operator's config name. A credential-less config
            # derives NO physical id (nil) instead of a provider-family
            # fallback.
            def derive_physical_id(instance_cfg:)
              Legion::Extensions::Llm::Bedrock::InstanceIdentity.derive_physical_id(instance_cfg: instance_cfg)
            end

            # ── Offering draft (evidence + metadata; NO weight) ───────────────
            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              tier = instance_cfg[:tier] || :cloud
              input_mods = extract_modalities(summary: model_data, field: :input_modalities)
              output_mods = extract_modalities(summary: model_data, field: :output_modalities)
              streaming = streaming_supported?(summary: model_data)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(
                  is_embedding: output_mods.include?('embedding'), streaming_supported: streaming
                ),
                capability_evidence: build_capability_evidence(
                  input_mods: input_mods, output_mods: output_mods,
                  streaming_supported: streaming, model_id: model_id
                ),
                context_evidence: build_context_evidence(model_id: model_id),
                max_output_evidence: build_max_output_evidence,
                embedding_dimensions_evidence: build_embedding_dimensions_evidence,
                model_revision_evidence: build_model_revision_evidence,
                tokenizer_evidence: build_tokenizer_evidence,
                quota_domains: build_quota_domains(instance_cfg: instance_cfg, model_id: model_id),
                metadata: build_offering_metadata(model_id: model_id, instance_key: instance_key),
                publication_source: :provider_catalog
              )
            end

            private

            # Authoritative operation evidence: an embedding model publishes
            # chat/stream_chat as :unsupported so a plain chat request can
            # never misroute to it; embed is published only for embedding
            # models.
            def build_operation_evidence(is_embedding:, streaming_supported:)
              now = Time.now.freeze
              if is_embedding
                embed_operations(now: now)
              else
                chat_operations(streaming_supported: streaming_supported, now: now)
              end
            end

            def embed_operations(now:)
              ops = %i[chat stream_chat image transcribe translate speak moderate]
              result = ops.to_h do |op|
                [op, op_evidence(operation: op, status: :unsupported, now: now)]
              end
              result[:embed] = op_evidence(operation: :embed, status: :supported, now: now)
              result[:count_tokens] = op_evidence(operation: :count_tokens, status: :unsupported, now: now)
              result
            end

            def chat_operations(streaming_supported:, now:)
              stream_status = streaming_supported ? :supported : :unknown
              {
                chat: op_evidence(operation: :chat, status: :supported, now: now),
                stream_chat: op_evidence(operation: :stream_chat, status: stream_status, now: now),
                embed: op_evidence(operation: :embed, status: :unsupported, now: now),
                image: op_evidence(operation: :image, status: :unsupported, now: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, now: now),
                translate: op_evidence(operation: :translate, status: :unsupported, now: now),
                speak: op_evidence(operation: :speak, status: :unsupported, now: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, now: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, now: now)
              }
            end

            def op_evidence(operation:, status:, now:)
              source = case status
                       when :unknown    then :default_false
                       when :supported  then :provider_catalog
                       else :provider_implementation
                       end
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: now
              )
            end

            def build_capability_evidence(input_mods:, output_mods:, streaming_supported:, model_id:)
              if output_mods.include?('embedding')
                return { embedding: cap_evidence(capability: :embedding, status: :supported,
                                                 source: :provider_catalog) }
              end

              evidence = { completion: cap_evidence(capability: :completion, status: :supported,
                                                    source: :provider_catalog) }
              if streaming_supported
                evidence[:streaming] = cap_evidence(capability: :streaming, status: :supported,
                                                    source: :provider_catalog)
              end
              if input_mods.include?('image')
                evidence[:vision] = cap_evidence(capability: :vision, status: :supported,
                                                 source: :provider_catalog)
              end
              # B10: per-model tool evidence, not a blanket catalog claim.
              # The invoke_model tool renderer is a real implementation for
              # Anthropic models; for the rest of the AWS catalog the gem has
              # no per-model fact, and the honest state is :unknown — a
              # fabricated :supported routes tool requests to models that
              # reject them with ValidationException.
              evidence[:tools] = if Legion::Extensions::Llm::Bedrock::ThinkingModes.anthropic_model?(model_id)
                                   cap_evidence(capability: :tools, status: :supported,
                                                source: :provider_implementation)
                                 else
                                   cap_evidence(capability: :tools, status: :unknown,
                                                source: :default_false)
                                 end
              evidence[:thinking] = cap_evidence(
                capability: :thinking,
                status: thinking_status_for(model_id: model_id),
                source: thinking_source_for(model_id: model_id)
              )
              evidence
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end

            def thinking_status_for(model_id:)
              thinking_model?(model_id: model_id) ? :supported : :unknown
            end

            def thinking_source_for(model_id:)
              thinking_model?(model_id: model_id) ? :provider_catalog : :default_false
            end

            def thinking_model?(model_id:)
              mid = model_id.to_s
              mid.match?(/anthropic\.claude-(sonnet-4|opus-4|haiku-4)/) ||
                mid.match?(/anthropic\.claude-3-[57]-sonnet/)
            end

            def build_context_evidence(model_id:)
              # B20: one CONTEXT_WINDOWS owner (Provider::CONTEXT_WINDOWS) —
              # the duplicated actor-side table (drift risk one edit away) is
              # gone.
              context_windows = Legion::Extensions::Llm::Bedrock::Provider::CONTEXT_WINDOWS
              ctx = context_windows.find { |prefix, _| model_id.start_with?(prefix) }&.last
              klass = Legion::Extensions::Llm::Inventory::ValueEvidence
              if ctx
                klass.new(status: :known, value: ctx, source: :provider_catalog)
              else
                klass.new(status: :unknown, source: :absent)
              end
            end

            def build_max_output_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_embedding_dimensions_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_model_revision_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_tokenizer_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def extract_modalities(summary:, field:)
              mods = if summary.respond_to?(field)
                       Array(summary.public_send(field))
                     elsif summary.is_a?(Hash)
                       Array(summary[field])
                     else
                       []
                     end
              mods.map { |m| m.to_s.downcase }
            end

            def streaming_supported?(summary:)
              if summary.respond_to?(:response_streaming_supported)
                summary.response_streaming_supported == true
              elsif summary.is_a?(Hash)
                summary[:response_streaming_supported] == true
              else
                false
              end
            end

            def build_quota_domains(instance_cfg:, model_id:)
              region = Legion::Extensions::Llm::Bedrock::InstanceIdentity.resolve_region(instance_cfg: instance_cfg)
              fingerprint = derive_account_fingerprint(instance_cfg: instance_cfg)
              return {} unless fingerprint

              domain_id = "aws:#{fingerprint}:#{region}:#{model_id}"
              { chat: domain_id, stream_chat: domain_id, embed: domain_id }
            end

            def derive_account_fingerprint(instance_cfg:)
              credential_input = instance_cfg[:bedrock_access_key_id] ||
                                 instance_cfg[:bearer_token] ||
                                 instance_cfg[:bedrock_profile]
              return nil unless credential_input

              ::Digest::SHA256.hexdigest(credential_input.to_s)[0, 8]
            end

            def build_offering_metadata(model_id:, instance_key:)
              # instance_id is the config name (identity); physical_id is the
              # secondary derived region/credential id (dedup/diagnostics).
              {
                raw_model: model_id,
                instance_id: instance_key.instance_id,
                physical_id: instance_key.physical_id
              }
            end

            # ── AWS control-plane client (shared by catalog + readiness) ──────

            # B14: the ReadinessResult contract carries no exception — a
            # bounded class name, not e.message (the metadata already holds
            # error_class).
            def readiness_failure(operation:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false,
                reason: "Bedrock #{operation} failed: #{error.class.name}",
                metadata: { error_class: error.class.name }
              )
            end

            def build_bedrock_client(instance_cfg:)
              require 'aws-sdk-bedrock'
              Aws::Bedrock::Client.new(client_options_for(instance_cfg: instance_cfg))
            end

            def client_options_for(instance_cfg:)
              opts = {
                region: Legion::Extensions::Llm::Bedrock::InstanceIdentity.resolve_region(instance_cfg: instance_cfg)
              }
              endpoint = instance_cfg[:bedrock_endpoint]
              opts[:endpoint] = endpoint if endpoint
              opts[:stub_responses] = true if instance_cfg[:bedrock_stub_responses] == true
              bearer = instance_cfg[:bearer_token]
              if bearer.is_a?(String) && !bearer.strip.empty?
                opts[:token_provider] = Aws::StaticTokenProvider.new(bearer)
              else
                creds = resolve_credentials(instance_cfg: instance_cfg)
                opts[:credentials] = creds if creds
              end
              opts.compact
            end

            def resolve_credentials(instance_cfg:)
              profile = instance_cfg[:bedrock_profile]
              return Aws::SharedCredentials.new(profile_name: profile) if profile.is_a?(String) && !profile.strip.empty?

              akid = instance_cfg[:bedrock_access_key_id]
              return nil unless akid.is_a?(String) && !akid.strip.empty?

              Aws::Credentials.new(akid, instance_cfg[:bedrock_secret_access_key], instance_cfg[:bedrock_session_token])
            end
          end
        end
      end
    end
  end
end
