# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Credential source discovery logic extracted from the Bedrock module
        # to keep Metrics/ModuleLength within the project limit.
        #
        # Extended onto the Bedrock module so all methods become module-level
        # class methods accessible as Bedrock.discover_instances etc.
        module CredentialDiscovery
          def unresolved_credential?(config)
            return false if config[:bedrock_profile]

            cred = config[:bearer_token] || config[:bedrock_access_key_id] || config[:api_key]
            return true if cred.nil?

            cred.to_s.match?(%r{\A(vault|env)://})
          end

          def discover_env_bearer(candidates)
            bearer = CredentialSources.env('AWS_BEARER_TOKEN_BEDROCK')
            return unless bearer

            candidates[:env_bearer] = {
              bearer_token: bearer,
              bedrock_region: CredentialSources.env('AWS_DEFAULT_REGION') || DEFAULT_REGION,
              tier: :cloud,
              source: CredentialSources.source_tag(:env, 'AWS_BEARER_TOKEN_BEDROCK'),
              credential_fingerprint: CredentialSources.credential_fingerprint(bearer)
            }
          end

          def discover_claude_bearer(candidates)
            claude_bearer = CredentialSources.claude_env_value('AWS_BEARER_TOKEN_BEDROCK')
            claude_bearer ||= claude_env_pattern_match
            return unless claude_bearer

            candidates[:claude] = {
              bearer_token: claude_bearer,
              bedrock_region: CredentialSources.claude_env_value('AWS_DEFAULT_REGION') || DEFAULT_REGION,
              tier: :cloud,
              source: CredentialSources.source_tag(:file, '~/.claude/settings.json', 'AWS_BEARER_TOKEN_BEDROCK'),
              credential_fingerprint: CredentialSources.credential_fingerprint(claude_bearer)
            }
          end

          def discover_env_sigv4(candidates)
            akid = CredentialSources.env('AWS_ACCESS_KEY_ID')
            skey = CredentialSources.env('AWS_SECRET_ACCESS_KEY')
            return unless akid && skey

            candidates[:env_sigv4] = {
              api_key: akid, bedrock_access_key_id: akid, bedrock_secret_access_key: skey,
              bedrock_session_token: CredentialSources.env('AWS_SESSION_TOKEN'),
              bedrock_region: CredentialSources.env('AWS_DEFAULT_REGION') || DEFAULT_REGION,
              tier: :cloud,
              source: CredentialSources.source_tag(:env, 'AWS_ACCESS_KEY_ID'),
              credential_fingerprint: CredentialSources.credential_fingerprint(akid)
            }.compact
          end

          def discover_settings(candidates)
            settings = CredentialSources.setting(:extensions, :llm, :bedrock)
            return unless settings.is_a?(Hash) && !settings.empty?

            # B15: operator-named instances are collected before the
            # top-level :settings (source-named) candidate — with first-wins
            # dedup, the operator's instance keeps its name over the
            # source-named fallback carrying the same credentials.
            settings_instances(settings).each do |name, config|
              next unless config.is_a?(Hash)

              normalized = dedup_config(normalize_instance_config(config))
              normalized[:source] = CredentialSources.source_tag(:settings,
                                                                 "extensions.llm.bedrock.instances.#{name}")
              normalized[:credential_fingerprint] = CredentialSources.config_fingerprint(normalized)
              candidates[name.to_sym] = normalized.merge(tier: :cloud)
            end

            default_config = dedup_config(normalize_instance_config(settings))
            return if default_config.empty?

            default_config[:source] = CredentialSources.source_tag(:settings, 'extensions.llm.bedrock')
            default_config[:credential_fingerprint] = CredentialSources.config_fingerprint(default_config)
            candidates[:settings] = default_config.merge(tier: :cloud)
          end

          def discover_broker(candidates)
            return unless defined?(Legion::Identity::Broker)

            broker_creds = broker_aws_credentials
            return unless broker_creds

            broker_creds[:source] = CredentialSources.source_tag(:broker, 'identity', 'aws')
            broker_creds[:credential_fingerprint] = CredentialSources.config_fingerprint(broker_creds)
            candidates[:broker] = broker_creds.merge(tier: :cloud)
          end

          # Scan Claude config env hash for any key containing all of
          # AWS, BEARER, TOKEN, and BEDROCK fragments (case-insensitive).
          def claude_env_pattern_match
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
          def broker_aws_credentials
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

          def settings_instances(config)
            instances = config[:instances] || config['instances']
            instances.is_a?(Hash) ? instances : {}
          end

          def normalize_instance_config(config)
            return {} if config.nil?

            normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            flatten_credential_subhash!(normalized)
            normalized[:bedrock_region]            ||= normalized.delete(:region)
            normalized[:bedrock_geo_prefix]        ||= normalized.delete(:geo_prefix)
            normalized[:bedrock_endpoint]          ||= normalized.delete(:endpoint)
            normalized[:bedrock_endpoint]          ||= normalized.delete(:base_url)
            normalized[:bedrock_endpoint]          ||= normalized.delete(:api_base)
            normalized[:bedrock_access_key_id]     ||= normalized.delete(:api_key) || normalized.delete(:access_key_id)
            normalized[:bedrock_secret_access_key] ||= normalized.delete(:secret_key)
            normalized[:bedrock_secret_access_key] ||= normalized.delete(:secret_access_key)
            normalized[:bedrock_session_token]     ||= normalized.delete(:session_token)
            normalized[:bedrock_profile]           ||= normalized.delete(:profile)
            normalized.compact.except(:instances)
          end

          # Flatten the documented credentials: sub-hash into the flat
          # provider config keys. Explicit flat keys win over sub-hash values.
          def flatten_credential_subhash!(normalized)
            creds = normalized.delete(:credentials)
            return unless creds.is_a?(::Hash)

            creds = creds.transform_keys(&:to_sym)
            normalized[:bearer_token]              ||= creds[:bearer_token]
            normalized[:bedrock_access_key_id]     ||= creds[:access_key_id]
            normalized[:bedrock_secret_access_key] ||= creds[:secret_access_key]
            normalized[:bedrock_session_token]     ||= creds[:session_token]
            normalized[:bedrock_profile]           ||= creds[:profile]
          end

          def dedup_config(config)
            key = config[:bedrock_access_key_id]
            key ? config.merge(api_key: key) : config
          end

          def sanitize_instance_config(config)
            config.except(:api_key)
          end
        end
      end
    end
  end
end
