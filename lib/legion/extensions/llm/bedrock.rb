# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/bedrock/provider'
require 'legion/extensions/llm/bedrock/version'

module Legion
  module Extensions
    module Llm
      # Amazon Bedrock provider extension namespace.
      module Bedrock
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :bedrock

        def self.default_settings
          {
            enabled: false,
            default_model: 'us.anthropic.claude-sonnet-4-6',
            region: 'us-east-2',
            bearer_token: nil,
            api_key: nil,
            secret_key: nil,
            session_token: nil,
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 3600,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
        end

        def self.provider_class
          Provider
        end

        def self.registry_publisher
          @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: PROVIDER_FAMILY)
        end
      end
    end
  end
end

Legion::Extensions::Llm::Configuration.register_provider_options(
  Legion::Extensions::Llm::Bedrock::Provider.configuration_options
)
