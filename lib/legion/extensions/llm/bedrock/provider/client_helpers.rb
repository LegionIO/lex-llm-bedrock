# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # AWS client construction, credential resolution, and low-level
          # response parsing utilities.
          module ClientHelpers
            private

            def bedrock_client
              @bedrock_client ||= Aws::Bedrock::Client.new(client_options)
            end

            def runtime_client
              @runtime_client ||= Aws::BedrockRuntime::Client.new(client_options)
            end

            def client_options
              opts = {
                region: region,
                endpoint: config.bedrock_endpoint,
                stub_responses: config.bedrock_stub_responses
              }

              if bearer_token_configured?
                opts[:token_provider] = Aws::StaticTokenProvider.new(config.bearer_token)
              else
                opts[:credentials] = credentials
              end

              opts.compact
            end

            def bearer_token_configured?
              config.respond_to?(:bearer_token) && !config.bearer_token.to_s.empty?
            end

            def credentials
              return Aws::SharedCredentials.new(profile_name: config.bedrock_profile) if config.bedrock_profile
              return nil unless config.bedrock_access_key_id

              if static_credentials_blocked?
                raise StaticCredentialsBlockedError,
                      'Static AWS credentials are disabled (security.block_static_aws_credentials=true); ' \
                      'use IAM roles'
              end
              log.warn('[bedrock] Using static AWS credentials — prefer IAM roles for production')
              Aws::Credentials.new(config.bedrock_access_key_id, config.bedrock_secret_access_key,
                                   config.bedrock_session_token)
            end

            def static_credentials_blocked?
              ::Legion::Settings[:extensions][:llm][:security][:block_static_aws_credentials] == true
            rescue NoMethodError, TypeError
              false
            end

            def credential_source
              return :static if config.bedrock_access_key_id
              return :profile if config.bedrock_profile

              :aws_sdk_default_chain
            end

            def parse_embedding_response(response, model:)
              body = parse_body(value(response, :body))
              vectors = body['embedding'] || body['embeddings'] || body.dig('data', 0, 'embedding')
              Legion::Extensions::Llm::Embedding.new(vectors: vectors, model: model,
                                                     input_tokens: body['inputTextTokenCount'])
            end

            def parse_body(body)
              body = body.read if body.respond_to?(:read)
              body = body.string if body.respond_to?(:string)
              body.is_a?(String) ? Legion::JSON.parse(body, symbolize_names: false) : body.to_h
            end

            def normalize_response(response)
              response.respond_to?(:to_h) ? response.to_h : {}
            end

            def value(object, key)
              return nil if object.nil?

              string_key = key.to_s

              val = safe_struct_access(object, key)
              return val unless val.nil?

              val = safe_struct_access(object, string_key)
              return val unless val.nil?

              return object.public_send(key) if object.respond_to?(key)

              if object.respond_to?(:to_h)
                hash = object.to_h
                return hash[key] if hash.key?(key)
                return hash[string_key] if hash.key?(string_key)
              end

              nil
            end

            def sanitize_log(str)
              return str unless str.is_a?(String)

              str.force_encoding('UTF-8').scrub('?')
            rescue EncodingError => e
              handle_exception(e, level: :debug, handled: true, operation: 'bedrock.provider.sanitize_log')
              str.inspect
            end

            def safe_struct_access(object, key)
              return nil unless object.respond_to?(:key?) && object.key?(key)

              object[key]
            rescue NameError
              nil
            end

            def safe_event_data(evt)
              evt.respond_to?(:to_h) ? evt.to_h : evt.inspect[0, 500]
            end
          end
        end
      end
    end
  end
end
