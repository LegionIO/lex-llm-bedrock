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
          #
          # Invoked by the Subscription actor as
          # `FleetWorker.handle_fleet_request(**message)`, where `message` is
          # the fully decoded delivery: the fleet envelope fields
          # (request_id, operation, provider, provider_instance, model,
          # params, signed_token, ...) plus delivery metadata. The whole
          # message is handed to the shared responder, which parses the
          # envelope and acks/rejects through the framework's manual_ack path.
          module FleetWorker
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(**message)
              log.debug do
                "bedrock.runner.fleet_worker.handle_fleet_request: request_id=#{message[:request_id]} " \
                  "provider_instance=#{message[:provider_instance] || 'default'}"
              end
              # L6: the responder takes only the payload and the family —
              # v3 dispatch is exact-only and never constructs a provider,
              # so the dead provider_class/provider_instances params are gone.
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: message,
                provider_family: Bedrock::PROVIDER_FAMILY
              )
            end
          end
        end
      end
    end
  end
end
