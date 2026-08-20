# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # Public dispatch surface: chat, stream, count_tokens, embed, complete.
          # These methods form the contract between the framework executor and the
          # Bedrock provider instance.
          module DispatchHelpers
            def chat(
              messages:,
              model:,
              temperature: nil,
              max_tokens: nil,
              tools: {},
              tool_prefs: nil,
              params: {},
              thinking: nil,
              **opts
            )
              enforce_canonical_messages!(messages)
              # Passthrough request params that do not map to an explicit
              # keyword reach the Converse payload, never silently dropped.
              params = params.merge(opts)
              enforce_model_allowed!(model_id(model))
              log.info { "bedrock.provider.chat: model=#{model_id(model)} messages=#{messages.size}" }

              if anthropic_model?(model_id(model)) && (thinking || (tools && !tools.empty?))
                return invoke_model_chat(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                         thinking:, params:)
              end

              request = Utils.deep_merge(
                converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:, thinking:),
                params
              )
              log_chat_request(request, model, tools, params, tool_prefs)

              start_time = Time.now
              response = converse_with_error_log(request, model, start_time)
              elapsed = ((Time.now - start_time) * 1000).round
              log_chat_response(response, model, elapsed)
              parse_converse_response(response, model_id(model))
            end

            def stream(messages:, model:, temperature: nil, max_tokens: nil, tools: {}, tool_prefs: nil, params: {},
                       thinking: nil, **opts, &)
              enforce_canonical_messages!(messages)
              # Passthrough request params that do not map to an explicit
              # keyword reach the Converse payload, never silently dropped.
              params = params.merge(opts)
              enforce_model_allowed!(model_id(model))
              log.info do
                "bedrock.provider.stream: model=#{model_id(model)} messages=#{messages.size} tools=#{tools.size}"
              end

              if anthropic_model?(model_id(model)) && (thinking || (tools && !tools.empty?))
                return invoke_model_stream(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                           thinking:, params:, &)
              end

              request = Utils.deep_merge(
                converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:, thinking:),
                params
              )
              log.debug do
                "bedrock.provider.stream: request prepared model=#{model_id(model)} tools=#{tools.size} " \
                  "tool_choice=#{tool_choice_label(tool_prefs)} param_keys=#{params.keys.map(&:to_s).sort.join(',')}"
              end
              thinking_config = request.dig(:additional_model_request_fields, :thinking)
              log.debug { "bedrock.provider.stream: thinking_config=#{thinking_config.inspect}" } if thinking_config

              start_time = Time.now
              result = stream_converse(request, model_id(model), request_id: params[:request_id], &)
              elapsed = ((Time.now - start_time) * 1000).round
              log.debug { "bedrock.provider.stream: completed model=#{model_id(model)} elapsed_ms=#{elapsed}" }
              result
            end

            def count_tokens(messages:, model:, system: nil, params: {}, **opts)
              enforce_canonical_messages!(messages)
              # Passthrough request params that do not map to an explicit
              # keyword reach the CountTokens payload, never silently dropped.
              params = params.merge(opts)
              log.debug { "bedrock.provider.count_tokens: model=#{model_id(model)}" }
              request = Utils.deep_merge(
                {
                  model_id: self.class.inference_profile_id(model_id(model), geo_prefix: geo_prefix),
                  input: {
                    converse: { messages: format_messages(messages), system: system_blocks(system) }.compact
                  }
                },
                params
              )
              response = runtime_client.count_tokens(**request)
              { input_tokens: value(response, :input_tokens), raw: normalize_response(response) }
            end

            def embed(text:, model:, dimensions: nil, params: {}, **opts)
              # Passthrough request params that do not map to an explicit
              # keyword reach the InvokeModel body, never silently dropped.
              params = params.merge(opts)
              mid = model_id(model)
              enforce_model_allowed!(mid)
              unless titan_embed?(mid)
                raise NotImplementedError,
                      "Bedrock embedding payload for #{mid} is not standardized"
              end

              log.info { "bedrock.provider.embed: model=#{mid}" }
              body = Utils.deep_merge({ inputText: text, dimensions: dimensions }.compact, params)
              response = runtime_client.invoke_model(
                model_id: mid,
                content_type: 'application/json',
                accept: 'application/json',
                body: Legion::JSON.generate(body)
              )
              parse_embedding_response(response, model: mid, text: text)
            end

            # The nameless ** accepts and ignores HTTP-style kwargs the base
            # contract carries (headers:) — Bedrock transport is the AWS SDK,
            # which owns its own request signing.
            def complete(messages, tools:, model:, params: {}, schema: nil,
                         thinking: nil, tool_prefs: nil, **, &)
              payload = params.is_a?(::Hash) ? params.dup : {}
              payload[:additional_model_request_fields] ||= {}
              payload[:additional_model_request_fields][:response_format] = schema if schema

              if block_given?
                stream(messages: messages, model: model, temperature: nil, max_tokens: nil,
                       tools: tools, tool_prefs: tool_prefs, params: payload, thinking: thinking, &)
              else
                chat(messages: messages, model: model, temperature: nil, max_tokens: nil,
                     tools: tools, tool_prefs: tool_prefs, params: payload, thinking: thinking)
              end
            end

            private

            def log_chat_request(request, model, tools, params, tool_prefs)
              log.debug do
                "bedrock.provider.chat: request prepared model=#{model_id(model)} tools=#{tools.size} " \
                  "tool_choice=#{tool_choice_label(tool_prefs)} param_keys=#{params.keys.map(&:to_s).sort.join(',')}"
              end
              thinking_config = request.dig(:additional_model_request_fields, :thinking)
              log.debug { "bedrock.provider.chat: thinking_config=#{thinking_config.inspect}" } if thinking_config
            end

            def converse_with_error_log(request, model, start_time)
              runtime_client.converse(**request)
            rescue StandardError => e
              elapsed = ((Time.now - start_time) * 1000).round
              log.error do
                "bedrock.provider.chat: converse failed model=#{model_id(model)} " \
                  "error=#{e.class}: #{e.message} elapsed_ms=#{elapsed}"
              end
              raise
            end

            def log_chat_response(response, model, elapsed)
              usage = value(response, :usage) || {}
              additional_fields = value(response, :additional_model_response_fields)
              af_keys = additional_fields.respond_to?(:to_h) ? additional_fields.to_h.keys.map(&:to_s).sort : []

              log.debug do
                "bedrock.provider.chat: response received model=#{model_id(model)} elapsed_ms=#{elapsed} " \
                  "usage=#{usage.inspect} additional_fields_keys=#{af_keys.inspect}"
              end

              dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)
              return unless dump_path

              raw_debug = response.respond_to?(:to_h) ? response.to_h : response.inspect[0, 2000]
              dump_file = File.join(dump_path, "bedrock_chat_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
              File.write(dump_file, Legion::JSON.pretty_generate(raw_debug))
              log.debug { "bedrock.provider.chat: raw response dumped to #{dump_file}" }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'bedrock.provider.log_chat_response')
            end
          end
        end
      end
    end
  end
end
