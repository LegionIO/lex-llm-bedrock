# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/bedrock/thinking_modes'
require 'legion/extensions/llm/bedrock/credential_discovery'
require 'legion/extensions/llm/bedrock/provider'
require 'legion/extensions/llm/bedrock/translator'
require 'legion/extensions/llm/bedrock/version'
require 'legion/logging/helper'
require_relative 'bedrock/actors/discovery_refresh'

module Legion
  module Extensions
    module Llm
      # Amazon Bedrock provider extension namespace.
      module Bedrock
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration
        extend CredentialDiscovery

        PROVIDER_FAMILY = :bedrock
        DEFAULT_REGION  = 'us-east-2'
        DEFAULT_CAPABILITIES = %i[completion streaming embedding].freeze

        def self.default_settings
          base = ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              region: 'us-east-1',
              geo_prefix: 'us',
              tier: :cloud,
              transport: :aws_sdk,
              credentials: {
                bearer_token: nil,
                access_key_id: nil,
                secret_access_key: nil,
                session_token: nil,
                profile: nil
              },
              provider: {
                region: DEFAULT_REGION,
                geo_prefix: 'us',
                endpoint: nil,
                stub_responses: false
              },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed tools]
              }
            }
          )
          base.merge(
            discovery_interval: 3600,
            security: { block_static_aws_credentials: false }
          )
        end

        def self.provider_class
          Provider
        end

        def self.registry_publisher
          @registry_publisher ||=
            Legion::Extensions::Llm::RegistryPublisher.new(provider_family: PROVIDER_FAMILY)
        end

        def self.discover_instances
          candidates = {}
          discover_env_bearer(candidates)
          discover_claude_bearer(candidates)
          discover_env_sigv4(candidates)
          discover_settings(candidates)
          discover_broker(candidates)
          CredentialSources.dedup_credentials(candidates)
                           .reject { |_, config| unresolved_credential?(config) }
                           .transform_values do |config|
            sanitized = sanitize_instance_config(config)
            sanitized[:capabilities] ||= DEFAULT_CAPABILITIES.dup
            sanitized
          end
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
