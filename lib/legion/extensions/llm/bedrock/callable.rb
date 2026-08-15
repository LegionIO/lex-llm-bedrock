# frozen_string_literal: true

require 'aws-sdk-bedrock'
require 'aws-sdk-bedrockruntime'
require 'legion/extensions/llm/error'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/routing/provider_outcome'

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Actor
          # Per-instance dispatch callable for a Bedrock provider instance.
          #
          # Wraps a per-instance Bedrock::Provider built from the instance
          # config and implements the fleet dispatch operations the coordinator
          # invokes (chat, stream_chat, embed, count_tokens) with ** passthrough,
          # plus the disconnect / normalize_dispatch_error(error:) contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          # Provider and AWS SDK errors propagate unchanged so
          # normalize_dispatch_error can classify them.
          class BedrockCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @provider = nil
              @disconnected = false
              @dispatch_mutex = Mutex.new
              @dispatch_count = 0
            end

            def disconnected?
              @disconnected
            end

            def dispatch_count
              @dispatch_mutex.synchronize { @dispatch_count }
            end

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @provider = nil
              @logger.debug { '[bedrock][callable] disconnected' }
            end

            def chat(messages:, model:, temperature: nil, max_tokens: nil, tools: {}, tool_prefs: nil,
                     thinking: nil, params: {}, **opts)
              dispatch! do
                provider.chat(messages: messages, model: model, temperature: temperature, max_tokens: max_tokens,
                              tools: tools, tool_prefs: tool_prefs, thinking: thinking, params: params.merge(opts))
              end
            end

            def stream_chat(messages:, model:, temperature: nil, max_tokens: nil, tools: {}, tool_prefs: nil,
                            thinking: nil, params: {}, **opts, &)
              dispatch! do
                provider.stream(messages: messages, model: model, temperature: temperature, max_tokens: max_tokens,
                                tools: tools, tool_prefs: tool_prefs, thinking: thinking,
                                params: params.merge(opts), &)
              end
            end

            def embed(text:, model:, dimensions: nil, params: {}, **opts)
              dispatch! { provider.embed(text: text, model: model, dimensions: dimensions, params: params.merge(opts)) }
            end

            def count_tokens(messages:, model:, system: nil, params: {}, **opts)
              dispatch! do
                provider.count_tokens(messages: messages, model: model, system: system, params: params.merge(opts))
              end
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

            # Per-instance Provider, built lazily from the instance config on
            # first dispatch.
            def provider
              @provider ||= Legion::Extensions::Llm::Bedrock::Provider.new(@instance_cfg)
            end

            def dispatch!
              if disconnected?
                raise Legion::Extensions::Llm::Inventory::Errors::CallableDisposedError,
                      'bedrock callable is disconnected'
              end

              @dispatch_mutex.synchronize { @dispatch_count += 1 }
              yield
            end

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
