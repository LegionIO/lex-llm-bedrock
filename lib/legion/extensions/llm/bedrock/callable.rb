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
          # config and implements the 0.8.0 fleet dispatch operations the
          # coordinator invokes (chat, stream_chat, embed, count_tokens) plus
          # the disconnect / normalize_dispatch_error(error:) contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          #
          # 0.8.0 callable boundary (WorkerExecution.dispatch_operation):
          # chat/stream_chat take messages POSITIONALLY (base Provider#chat
          # form); count_tokens takes the messages: kwarg. temperature and
          # max_tokens are Canonical::Params members (05 O4), never named
          # completion keys — the folded wire params become a Canonical::Params
          # at this boundary, because the 0.8.0 renderer reads params.temperature
          # / params.max_tokens (a raw Hash would NoMethodError).
          # Provider and AWS SDK errors propagate unchanged so
          # normalize_dispatch_error can classify them.
          class BedrockCallable
            # Keys the base Provider exposes as named kwargs for the completion
            # operations. Anything else the fleet passes (sampling scalars,
            # `temperature` — a Canonical::Params member, 05 O4) is folded into
            # Canonical::Params at the dispatch boundary.
            COMPLETION_NAMED_KEYS = %i[tools tool_prefs thinking].freeze
            COUNT_TOKENS_NAMED_KEYS = %i[system].freeze
            EMBED_NAMED_KEYS = %i[dimensions].freeze

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

            def chat(messages, model:, **rest)
              dispatch! do
                # Canonical boundary (N x N law): pipeline dispatch delivers
                # Canonical::Message objects only. Hash/legacy shapes are the
                # bypass class — reject loudly, never coerce.
                provider.enforce_canonical_messages!(messages)
                named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
                provider.chat(messages: messages, model: model, params: canonical_params(params), **named)
              end
            end

            def stream_chat(messages, model:, **rest, &)
              dispatch! do
                provider.enforce_canonical_messages!(messages)
                named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
                provider.stream(messages: messages, model: model, params: canonical_params(params), **named, &)
              end
            end

            # B19: unowned fleet params are not forwarded — the exact
            # execution binding carries no payload the operation does not own
            # (the old params passthrough reached the InvokeModel body
            # silently). Only the operation's named keys cross the boundary.
            def embed(text:, model:, **rest)
              dispatch! do
                named, _params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
                provider.embed(text: text, model: model, **named)
              end
            end

            # The fleet WorkerExecution calls count_tokens with the messages:
            # KWARG (worker_execution.rb) — only chat/stream_chat are positional.
            def count_tokens(messages:, model:, **rest)
              dispatch! do
                provider.enforce_canonical_messages!(messages)
                named, _params = split_fleet_kwargs(rest, COUNT_TOKENS_NAMED_KEYS)
                provider.count_tokens(messages: messages, model: model, **named)
              end
            end

            def normalize_dispatch_error(error:)
              # B9: the base reason policy (10 §1E) — the bounded exception
              # CLASS NAME; never a response body, credential, endpoint, or
              # exception message (AWS SDK messages embed request context).
              reason = error.class.name
              reason = 'UnknownError' if reason.nil? || reason.empty?

              kind = classify_error(error: error)

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason:
              )
            end

            private

            # Per-instance Provider, built lazily from the instance config on
            # first dispatch.
            def provider
              @provider ||= Legion::Extensions::Llm::Bedrock::Provider.new(@instance_cfg)
            end

            # The 0.8.0 completion funnel receives canonical values only
            # (08 F3): the folded wire params become a Canonical::Params at the
            # dispatch boundary — temperature is a params member (05 O4), never
            # a kwarg. from_hash accepts canonical keys and folds unknowns into
            # the metadata member (04 L5) — nothing is dropped.
            def canonical_params(params)
              Legion::Extensions::Llm::Canonical::Params.from_hash(params)
            end

            # Split the fleet's **rest into the provider's named completion
            # kwargs and a payload params hash (any passed :params merged with
            # the remaining unknown keys).
            def split_fleet_kwargs(rest, named_keys)
              named = rest.slice(*named_keys)
              extra = rest.reject { |key, _| named.key?(key) }
              params = (extra.delete(:params) || {}).to_h.merge(extra)
              [named, params]
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
