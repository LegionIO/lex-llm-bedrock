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
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :bedrock

        DEFAULT_REGION = 'us-east-2'

        def self.default_settings
          {
            enabled: false,
            default_model: 'us.anthropic.claude-sonnet-4-6',
            region: DEFAULT_REGION,
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

        def self.discover_instances
          candidates = {}
          discover_env_bearer(candidates)
          discover_claude_bearer(candidates)
          discover_env_sigv4(candidates)
          discover_settings(candidates)
          discover_broker(candidates)
          CredentialSources.dedup_credentials(candidates)
        end

        def self.discover_env_bearer(candidates)
          bearer = CredentialSources.env('AWS_BEARER_TOKEN_BEDROCK')
          return unless bearer

          candidates[:env_bearer] = {
            bearer_token: bearer,
            bedrock_region: CredentialSources.env('AWS_DEFAULT_REGION') || DEFAULT_REGION,
            tier: :cloud
          }
        end

        def self.discover_claude_bearer(candidates)
          claude_bearer = CredentialSources.claude_env_value('AWS_BEARER_TOKEN_BEDROCK')
          claude_bearer ||= claude_env_pattern_match
          return unless claude_bearer

          candidates[:claude] = {
            bearer_token: claude_bearer,
            bedrock_region: CredentialSources.claude_env_value('AWS_DEFAULT_REGION') || DEFAULT_REGION,
            tier: :cloud
          }
        end

        def self.discover_env_sigv4(candidates)
          akid = CredentialSources.env('AWS_ACCESS_KEY_ID')
          skey = CredentialSources.env('AWS_SECRET_ACCESS_KEY')
          return unless akid && skey

          candidates[:env_sigv4] = {
            api_key: akid, bedrock_access_key_id: akid, bedrock_secret_access_key: skey,
            bedrock_session_token: CredentialSources.env('AWS_SESSION_TOKEN'),
            bedrock_region: CredentialSources.env('AWS_DEFAULT_REGION') || DEFAULT_REGION, tier: :cloud
          }.compact
        end

        def self.discover_settings(candidates)
          settings = CredentialSources.setting(:extensions, :llm, :bedrock)
          candidates[:settings] = settings.merge(tier: :cloud) if settings.is_a?(Hash) && !settings.empty?
        end

        def self.discover_broker(candidates)
          return unless defined?(Legion::Identity::Broker)

          broker_creds = broker_aws_credentials
          candidates[:broker] = broker_creds.merge(tier: :cloud) if broker_creds
        end

        # Scan Claude config env hash for any key containing all of
        # AWS, BEARER, TOKEN, and BEDROCK fragments (case-insensitive).
        def self.claude_env_pattern_match
          env_hash = CredentialSources.claude_config_value(:env)
          return nil unless env_hash.is_a?(Hash)

          fragments = %w[AWS BEARER TOKEN BEDROCK]
          _key, value = env_hash.find do |k, _v|
            upper = k.to_s.upcase
            fragments.all? { |frag| upper.include?(frag) }
          end
          value
        end

        # Fetch AWS credentials from the Legion Identity Broker.
        def self.broker_aws_credentials
          return nil unless defined?(Legion::Identity::Broker)

          creds = Legion::Identity::Broker.credentials_for(:aws)
          return nil unless creds.is_a?(Hash)

          akid = creds[:access_key_id] || creds['access_key_id']
          return nil unless akid

          { api_key: akid, bedrock_access_key_id: akid,
            bedrock_secret_access_key: creds[:secret_access_key] || creds['secret_access_key'],
            bedrock_session_token: creds[:session_token] || creds['session_token'],
            bedrock_region: creds[:region] || creds['region'] || DEFAULT_REGION }.compact
        end
      end
    end
  end
end

if Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
  Legion::Extensions::Llm::Configuration.register_provider_options(
    Legion::Extensions::Llm::Bedrock::Provider.configuration_options
  )
end

Legion::Extensions::Llm::Bedrock.register_discovered_instances
