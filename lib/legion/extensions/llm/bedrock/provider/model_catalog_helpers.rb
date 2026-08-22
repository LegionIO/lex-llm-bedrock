# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # Model catalog (provider-native model facts) and health/readiness helpers.
          #
          # Offering production is the discovery actor's writer path
          # (OfferingDraft + Registry publication, 07 C1); the base read path
          # discover_offerings serves the activated inventory offerings from the
          # Registry snapshot (07 C5). The legacy ModelOffering production chain
          # is deleted with the 0.8.0 contract cut.
          module ModelCatalogHelpers
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

            private

            def fetch_model_detail(model_name)
              ctx = CONTEXT_WINDOWS.find { |prefix, _| model_name.start_with?(prefix) }&.last
              ctx ? { context_window: ctx } : nil
            end

            def titan_embed?(model)
              model.to_s.include?('titan-embed')
            end

            # B11: the dispatch/render path no longer remaps model ids —
            # the Selection's model is the wire model (R8: exact execution
            # stays exact). Alias resolution is an explicit edge API
            # (ClassMethods#resolve_model_id), never a render-path authority.
            def model_id(model)
              model.respond_to?(:id) ? model.id : model
            end
          end
        end
      end
    end
  end
end
