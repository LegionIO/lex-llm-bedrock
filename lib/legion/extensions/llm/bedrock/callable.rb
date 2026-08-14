# frozen_string_literal: true

require 'legion/extensions/llm/routing/provider_outcome'

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Actor
          # Callable wrapper for a Bedrock provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          class BedrockCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[bedrock][callable] disconnected' }
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]

              kind = classify_error(error: error)

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def classify_error(error:)
              case error
              when Aws::BedrockRuntime::Errors::ThrottlingException,
                   Aws::Bedrock::Errors::ThrottlingException
                :rate_limited
              when Aws::BedrockRuntime::Errors::ModelNotReadyException,
                   Aws::Bedrock::Errors::ModelNotReadyException
                :model_not_ready
              when Aws::BedrockRuntime::Errors::AccessDeniedException,
                   Aws::Bedrock::Errors::AccessDeniedException
                :authorization
              when Aws::BedrockRuntime::Errors::ValidationException,
                   Aws::Bedrock::Errors::ValidationException
                :invalid_request
              when Aws::BedrockRuntime::Errors::ResourceNotFoundException,
                   Aws::Bedrock::Errors::ResourceNotFoundException
                :model_missing
              when Aws::BedrockRuntime::Errors::ServiceUnavailableException,
                   Aws::Bedrock::Errors::ServiceUnavailableException
                # Explicit flat service-unavailable from AWS = instance_unavailable
                :instance_unavailable
              when Aws::BedrockRuntime::Errors::ServiceError,
                   Aws::Bedrock::Errors::ServiceError
                classify_service_error(error: error)
              else
                classify_generic_error(error: error)
              end
            end

            def classify_service_error(error:)
              status = error.respond_to?(:http_status_code) ? error.http_status_code : nil
              case status
              when 429 then :rate_limited
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              # NEVER classify raw 503/5xx as instance_unavailable by status alone.
              # Only the explicit ServiceUnavailableException (handled above) justifies
              # instance_unavailable. Everything else is request-local.
              when 503, 529 then :overloaded
              else :provider_error
              end
            end

            def classify_generic_error(error:)
              if overloaded_error?(error: error)
                :overloaded
              elsif timeout_error?(error: error)
                :timeout
              elsif connection_error?(error: error)
                :connection_failure
              else
                :provider_error
              end
            end

            def overloaded_error?(error:)
              error.is_a?(Legion::Extensions::Llm::OverloadedError)
            rescue NameError
              false
            end

            def timeout_error?(error:)
              error.is_a?(Timeout::Error) ||
                error.is_a?(Net::ReadTimeout) ||
                error.is_a?(Net::OpenTimeout) ||
                error.message.to_s.include?('timeout')
            end

            def connection_error?(error:)
              error.is_a?(Errno::ECONNREFUSED) ||
                error.is_a?(Errno::ECONNRESET) ||
                error.is_a?(SocketError) ||
                error.message.to_s.include?('connection refused')
            end
          end
        end
      end
    end
  end
end
