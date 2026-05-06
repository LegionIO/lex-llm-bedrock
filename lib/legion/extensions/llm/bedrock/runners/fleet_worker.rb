# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/bedrock/provider'

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Runners
          # Runner entrypoint for Bedrock fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Bedrock::PROVIDER_FAMILY,
                provider_class: Bedrock::Provider,
                provider_instances: -> { Bedrock.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
