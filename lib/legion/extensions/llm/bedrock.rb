# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/bedrock/provider'
require 'legion/extensions/llm/bedrock/version'

module Legion
  module Extensions
    module Llm
      # Amazon Bedrock provider extension namespace.
      module Bedrock # rubocop:disable Metrics/ModuleLength
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :bedrock

        DEFAULT_REGION = 'us-east-2'

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              default_model: 'us.anthropic.claude-sonnet-4-6',
              tier: :frontier,
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
                endpoint: nil,
                stub_responses: false
              },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed],
                lanes: [],
                concurrency: 4,
                queue_suffix: nil
              }
            }
          )
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
          return unless settings.is_a?(Hash) && !settings.empty?

          default_config = normalize_instance_config(settings)
          candidates[:settings] = default_config.merge(tier: :cloud) unless default_config.empty?

          settings_instances(settings).each do |name, config|
            next unless config.is_a?(Hash)

            candidates[name.to_sym] = normalize_instance_config(config).merge(tier: :cloud)
          end
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

        def self.settings_instances(config)
          instances = config[:instances] || config['instances']
          instances.is_a?(Hash) ? instances : {}
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:bedrock_region] ||= normalized.delete(:region)
          normalized[:bedrock_endpoint] ||= normalized.delete(:endpoint)
          normalized[:bedrock_endpoint] ||= normalized.delete(:base_url)
          normalized[:bedrock_endpoint] ||= normalized.delete(:api_base)
          normalized[:bedrock_access_key_id] ||= normalized[:api_key] || normalized.delete(:access_key_id)
          normalized[:bedrock_secret_access_key] ||= normalized.delete(:secret_key)
          normalized[:bedrock_secret_access_key] ||= normalized.delete(:secret_access_key)
          normalized[:bedrock_session_token] ||= normalized.delete(:session_token)
          normalized[:bedrock_profile] ||= normalized.delete(:profile)
          normalized.compact.except(:instances)
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options) if
          Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
      end
    end
  end
end

Legion::Extensions::Llm::Bedrock.register_discovered_instances
