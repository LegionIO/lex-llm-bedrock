# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Builds sanitized lex-llm registry envelopes for Bedrock provider state.
        class RegistryEventBuilder
          def readiness(readiness)
            registry_event_class.public_send(
              readiness[:ready] ? :available : :unavailable,
              provider_offering(readiness),
              runtime: runtime_metadata,
              health: readiness_health(readiness),
              metadata: readiness_metadata(readiness)
            )
          end

          def offering_available(offering, readiness:)
            registry_event_class.available(
              offering,
              runtime: runtime_metadata,
              health: offering_health(readiness),
              metadata: offering_metadata
            )
          end

          private

          def provider_offering(readiness)
            {
              provider_family: :bedrock,
              provider_instance: provider_instance,
              transport: :aws_sdk,
              model: 'provider-readiness',
              usage_type: :inference,
              capabilities: [],
              health: readiness_health(readiness),
              metadata: { lex: :llm_bedrock, provider_readiness: true }
            }
          end

          def readiness_health(readiness)
            health = {
              ready: readiness[:ready] == true,
              status: readiness[:ready] ? :available : :unavailable,
              checked: readiness[:checked] != false
            }
            add_readiness_error(health, readiness)
          end

          def add_readiness_error(health, source)
            error_class = source[:error] || source['error']
            error_message = source[:message] || source['message']
            health[:error_class] = error_class if error_class
            health[:error] = error_message if error_message
            health
          end

          def offering_health(readiness)
            ready = readiness.fetch(:ready, true) == true
            { ready:, status: ready ? :available : :degraded, checked: readiness[:checked] != false }
          end

          def readiness_metadata(readiness)
            {
              extension: :lex_llm_bedrock,
              provider: :bedrock,
              configured: readiness[:configured] == true,
              live: readiness[:live] == true
            }
          end

          def offering_metadata
            { extension: :lex_llm_bedrock, provider: :bedrock }
          end

          def runtime_metadata
            { node: provider_instance }
          end

          def provider_instance
            :bedrock
          end

          def registry_event_class
            ::Legion::Extensions::Llm::Routing::RegistryEvent
          end
        end
      end
    end
  end
end
