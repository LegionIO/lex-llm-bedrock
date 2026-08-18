# frozen_string_literal: true

require 'legion/extensions/llm/bedrock'
require 'legion/extensions/llm/bedrock/runners/fleet_worker'

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError => e
  Legion::Extensions::Llm::Bedrock.handle_exception(
    e,
    level: :debug,
    handled: true,
    operation: 'bedrock.actor.fleet_worker.load_subscription'
  )
end

unless defined?(Legion::Extensions::Actors::Subscription)
  raise LoadError, 'LegionIO actor runtime is required for Bedrock fleet worker'
end

require 'legion/extensions/llm/fleet/provider_responder'

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Actor
          # Subscription actor for Bedrock fleet request consumption.
          #
          # The Subscription dispatch path invokes the runner directly as
          # `runner_class.send(runner_function, **message)` where `message` is
          # the fully decoded delivery (envelope fields plus metadata headers).
          # runner_class must therefore be the runner constant itself (a String
          # cannot be `send`-ed) and the runner function must accept the
          # decoded message as keyword arguments.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            include Legion::Logging::Helper

            def runner_class
              Legion::Extensions::Llm::Bedrock::Runners::FleetWorker
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              instances = Bedrock.discover_instances
              enabled = Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(instances)
              log.debug { "bedrock.actor.fleet_worker.enabled?: instances=#{instances.size} enabled=#{enabled}" }
              enabled
            end
          end
        end
      end
    end
  end
end
