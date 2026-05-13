# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/bedrock'
require 'legion/logging/helper'

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Runners
          # Runner entrypoint for Bedrock fleet request execution.
          module FleetWorker
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              log.debug do
                "bedrock.runner.fleet_worker.handle_fleet_request: request_id=#{payload_value(payload, :request_id)} " \
                  "provider_instance=#{payload_value(payload, :provider_instance) || 'default'}"
              end
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Bedrock::PROVIDER_FAMILY,
                provider_class: Bedrock::Provider,
                provider_instances: -> { Bedrock.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end

            def payload_value(payload, key)
              return nil unless payload.respond_to?(:[])

              payload[key] || payload[key.to_s]
            end
          end
        end
      end
    end
  end
end
