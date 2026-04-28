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
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            discovery: { enabled: false, live: false, regions: %w[us-east-1 us-west-2] },
            instance: {
              endpoint: 'https://bedrock-runtime.us-east-1.amazonaws.com',
              region: 'us-east-1',
              tier: :frontier,
              transport: :aws_sdk,
              credentials: {
                provider: 'aws-sdk-default-chain',
                access_key_id: 'env://AWS_ACCESS_KEY_ID',
                secret_access_key: 'env://AWS_SECRET_ACCESS_KEY',
                session_token: 'env://AWS_SESSION_TOKEN',
                profile: 'env://AWS_PROFILE'
              },
              usage: { inference: true, embedding: true, token_counting: true },
              limits: { concurrency: 4 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::Bedrock::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::Bedrock::Provider)
