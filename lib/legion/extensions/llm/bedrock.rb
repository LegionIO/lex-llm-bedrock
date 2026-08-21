# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/bedrock/thinking_modes'
require 'legion/extensions/llm/bedrock/credential_discovery'
require 'legion/extensions/llm/bedrock/instance_identity'
require 'legion/extensions/llm/bedrock/provider'
require 'legion/extensions/llm/bedrock/translator'
require 'legion/extensions/llm/bedrock/version'
require 'legion/logging/helper'
require 'legion/extensions/llm/bedrock/actors/discovery_refresh'

module Legion
  module Extensions
    module Llm
      # Amazon Bedrock provider extension namespace.
      module Bedrock
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
          base.merge(security: { block_static_aws_credentials: false })
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances
          candidates = {}
          # B15: dedup is first-source-wins, so operator-configured
          # instances (settings) are collected FIRST — they win their own
          # credentials over source-named candidates (env/claude/broker),
          # which are fallbacks. The old order let an env credential with
          # the same value shadow an operator-named instance, renaming it
          # to the source name (env_bearer, claude, ...).
          discover_settings(candidates)
          discover_env_bearer(candidates)
          discover_claude_bearer(candidates)
          discover_env_sigv4(candidates)
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
