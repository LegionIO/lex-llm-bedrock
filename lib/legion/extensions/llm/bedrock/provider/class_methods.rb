# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # Class-level methods for the Bedrock provider, applied via `extend`.
          module ClassMethods
            INFERENCE_PROFILE_PREFIXES = %w[anthropic. meta. mistral. cohere. ai21.].freeze

            def slug = 'bedrock'
            def default_transport = :aws_sdk
            def default_tier = :cloud

            def configuration_options
              %i[
                bedrock_region
                bedrock_endpoint
                bedrock_access_key_id
                bedrock_secret_access_key
                bedrock_session_token
                bedrock_geo_prefix
                bedrock_profile
                bedrock_stub_responses
                bearer_token
              ]
            end

            def configuration_requirements = []
            def capabilities = Capabilities

            def registry_publisher
              Legion::Extensions::Llm::Bedrock.registry_publisher
            end

            def resolve_model_id(model_id, **)
              ALIASES.fetch(model_id.to_s, model_id.to_s)
            end

            def inference_profile_id(model, geo_prefix: 'us', region: nil)
              return model if model.start_with?('arn:')

              canonical = model.sub(/\A(?:us|eu|ap)\./, '')
              return canonical unless INFERENCE_PROFILE_PREFIXES.any? { |p| canonical.start_with?(p) }

              prefix = normalize_geo_prefix(geo_prefix || region)
              "#{prefix}.#{canonical}"
            end

            def normalize_geo_prefix(value)
              candidate = value.to_s.downcase
              %w[us eu ap].include?(candidate) ? candidate : 'us'
            end
          end
        end
      end
    end
  end
end
