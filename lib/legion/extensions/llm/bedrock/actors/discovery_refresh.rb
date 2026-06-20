# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Actor
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Style/Documentation
            include Legion::Logging::Helper

            if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              include Legion::Extensions::Llm::Inventory::ScopedRefresher
            end

            REFRESH_INTERVAL = 1800
            EMBED_TYPES = %i[embed embedding].freeze

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return REFRESH_INTERVAL unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :bedrock, :discovery_interval) || REFRESH_INTERVAL
            end

            def scope_key(**)
              { provider: :bedrock }
            end

            def compute_lanes_for_scope(**)
              return [] unless defined?(Legion::LLM::Call::Registry)

              settings = Legion::Settings.dig(:extensions, :llm, :bedrock) || {}
              fleet_enabled = settings.dig(:fleet, :dispatch, :enabled)

              instances = Legion::LLM::Call::Registry.all_instances.select do |e|
                (e[:provider] || '').to_sym == :bedrock
              end

              instances.flat_map { |inst| lanes_for_instance(inst, fleet_enabled: fleet_enabled) }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'bedrock.actor.discovery_refresh.compute_lanes')
              []
            end

            def credential_hash(**)
              raw = Legion::Settings.dig(:extensions, :llm, :bedrock) || {}
              Digest::SHA256.hexdigest(raw[:api_key].to_s + raw[:instances].to_s)[0, 16]
            end

            def manual(**)
              tick if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher) &&
                      self.class.ancestors.include?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'bedrock.actor.discovery_refresh')
            end

            private

            def lanes_for_instance(instance, fleet_enabled: false)
              adapter = instance[:adapter]
              return [] unless adapter.respond_to?(:discover_offerings)

              Array(adapter.discover_offerings(live: false)).flat_map do |offering|
                build_offering_lanes(offering, instance, fleet_enabled: fleet_enabled)
              end
            end

            def build_offering_lanes(offering, instance, fleet_enabled: false)
              raw_tier = offering[:tier] || :cloud
              type = EMBED_TYPES.include?(offering[:type]&.to_sym) ? :embedding : :inference

              lane_fields = {
                tier: raw_tier,
                provider_family: :bedrock,
                instance_id: instance[:id] || instance[:instance_id] || 'default',
                type: type,
                model: offering[:model]
              }

              lane = build_lane(offering, lane_fields)
              result = [lane]

              if fleet_enabled && type == :inference
                fleet_fields = lane_fields.merge(tier: :fleet)
                result << lane.merge(
                  id: Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(fleet_fields),
                  tier: :fleet
                )
              end

              result
            end

            def build_lane(offering, lane_fields)
              capabilities = normalize_capabilities(offering[:capabilities])
              {
                id: Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(lane_fields),
                tier: lane_fields[:tier],
                provider_family: :bedrock,
                instance_id: lane_fields[:instance_id],
                model: offering[:model],
                canonical_model_alias: offering[:canonical_model_alias],
                type: lane_fields[:type],
                capabilities: capabilities,
                limits: offering[:limits] || {},
                enabled: offering.fetch(:enabled, true),
                cost: offering[:cost] || {}
              }
            end

            def normalize_capabilities(caps)
              return [] unless defined?(Legion::Extensions::Llm::Inventory::Capabilities)
              return [] unless Legion::Extensions::Llm::Inventory::Capabilities.respond_to?(:normalize)

              Legion::Extensions::Llm::Inventory::Capabilities.normalize(caps)
            end
          end
        end
      end
    end
  end
end
