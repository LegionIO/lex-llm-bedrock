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
            # 08 F3: the completion funnel receives canonical values only —
            # params is a Canonical::Params (the callable folds the wire params
            # at the boundary); temperature/max_tokens are params members
            # (05 O4), never named completion keys.
            #
            # B1: the dialect fork has one owner — ThinkingModes, shared with
            # the Translator (the old object-truthiness thinking predicate is
            # deleted). B3: tools/thinking are enforced canonical at this
            # seam, once, before any rendering (the H3 funnel the custom
            # funnel had skipped). B5: system-role messages are folded into
            # the single system source at the edge; the dialect renderers read
            # the folded value only.
            def chat(messages:, model:, tools: {}, tool_prefs: nil, params: nil, thinking: nil)
              enforce_canonical_messages!(messages)
              # H3: tools is Hash<name, ToolDefinition> or nil — nil
              # canonicalizes to the empty set (no tools).
              tools = enforce_canonical_tools!(tools) || {}
              enforce_canonical_thinking!(thinking)
              enforce_model_allowed!(model_id(model))
              system, messages = split_system_messages(messages)
              log.info { "bedrock.provider.chat: model=#{model_id(model)} messages=#{messages.size}" }

              if ThinkingModes.invoke_model_target?(model_id: model_id(model), thinking: thinking, tools: tools)
                return invoke_model_chat(messages:, model:, tools:, tool_prefs:, system:, thinking:, params:)
              end

              request = converse_request(messages, model:, params:, tools:, tool_prefs:, system:, thinking:)
              log_chat_request(request, model, tools, params, tool_prefs)

              start_time = Time.now
              response = converse_with_error_log(request, model, start_time)
              elapsed = ((Time.now - start_time) * 1000).round
              log_chat_response(response, model, elapsed)
              parse_converse_response(response, model_id(model))
            end

            def stream(messages:, model:, tools: {}, tool_prefs: nil, params: nil, thinking: nil, &)
              enforce_canonical_messages!(messages)
              # H3: tools is Hash<name, ToolDefinition> or nil — nil
              # canonicalizes to the empty set (no tools).
              tools = enforce_canonical_tools!(tools) || {}
              enforce_canonical_thinking!(thinking)
              enforce_model_allowed!(model_id(model))
              system, messages = split_system_messages(messages)
              log.info do
                "bedrock.provider.stream: model=#{model_id(model)} messages=#{messages.size} tools=#{tools.size}"
              end

              if ThinkingModes.invoke_model_target?(model_id: model_id(model), thinking: thinking, tools: tools)
                return invoke_model_stream(messages:, model:, tools:, tool_prefs:, system:, thinking:, params:, &)
              end

              request = converse_request(messages, model:, params:, tools:, tool_prefs:, system:, thinking:)
              log.debug do
                "bedrock.provider.stream: request prepared model=#{model_id(model)} tools=#{tools.size} " \
                  "tool_choice=#{tool_choice_label(tool_prefs)} param_keys=#{param_keys(params)}"
              end
              thinking_config = request.dig(:additional_model_request_fields, :thinking)
              log.debug { "bedrock.provider.stream: thinking_config=#{thinking_config.inspect}" } if thinking_config

              start_time = Time.now
              result = stream_converse(request, model_id(model), request_id: request_id_from_params(params), &)
              elapsed = ((Time.now - start_time) * 1000).round
              log.debug { "bedrock.provider.stream: completed model=#{model_id(model)} elapsed_ms=#{elapsed}" }
              result
            end

            # B19: the exact execution binding carries no unowned payload —
            # the CountTokens wire is model_id + input.converse only. The old
            # params-merge (arbitrary fleet kwargs into the AWS SDK request)
            # is deleted; the nameless ** absorbs and ignores unowned keys
            # (like complete does).
            def count_tokens(messages:, model:, system: nil, **)
              enforce_canonical_messages!(messages)
              log.debug { "bedrock.provider.count_tokens: model=#{model_id(model)}" }
              request = {
                model_id: self.class.inference_profile_id(model_id(model), geo_prefix: geo_prefix),
                input: {
                  converse: { messages: format_messages(messages), system: system_blocks(system) }.compact
                }
              }
              response = runtime_client.count_tokens(**request)
              { input_tokens: value(response, :input_tokens), raw: normalize_response(response) }
            end

            # B19: the Titan InvokeModel body is the documented vocabulary
            # (inputText, dimensions) — the old params deep_merge (arbitrary
            # fleet kwargs silently into the wire body) is deleted; the
            # nameless ** absorbs and ignores unowned keys.
            def embed(text:, model:, dimensions: nil, **)
              mid = model_id(model)
              enforce_model_allowed!(mid)
              unless titan_embed?(mid)
                raise NotImplementedError,
                      "Bedrock embedding payload for #{mid} is not standardized"
              end

              log.info { "bedrock.provider.embed: model=#{mid}" }
              body = { inputText: text, dimensions: dimensions }.compact
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
            def complete(messages, tools:, model:, params: nil, schema: nil,
                         thinking: nil, tool_prefs: nil, **, &)
              canonical = params
              if schema
                source = params ? params.to_h : {}
                canonical = Legion::Extensions::Llm::Canonical::Params.from_hash(
                  source.merge(response_format: schema)
                )
              end

              if block_given?
                stream(messages: messages, model: model, tools: tools, tool_prefs: tool_prefs,
                       params: canonical, thinking: thinking, &)
              else
                chat(messages: messages, model: model, tools: tools, tool_prefs: tool_prefs,
                     params: canonical, thinking: thinking)
              end
            end

            private

            # Canonical params log projection (08 F3: the funnel carries
            # canonical values, not a raw hash).
            def param_keys(params)
              return '' if params.nil?

              params.to_h.keys.map(&:to_s).sort.join(',')
            end

            # The stream correlation id travels as a folded wire param (04 L5
            # metadata) — never a named completion key.
            def request_id_from_params(params)
              params&.metadata&.[](:request_id)
            end

            # B5: the system prompt has one canonical source — the folded
            # member value. System-role messages are bridge residue folded at
            # this edge (the vLLM bridge law); the dialect renderers read the
            # folded value only and never re-source from messages.
            def split_system_messages(messages)
              system_parts = []
              remaining = []
              messages.each do |message|
                if message.role == :system
                  text = canonical_content_text(message.content, joiner: "\n")
                  system_parts << text unless text.strip.empty?
                else
                  remaining << message
                end
              end
              [system_parts.empty? ? nil : system_parts.join("\n"), remaining]
            end

            # B3: the thinking half of the dispatch boundary —
            # Canonical::Thinking::Config only. The fleet wire hash is the
            # W4 rehydration boundary's job (core side); a non-canonical value
            # here is a boundary violation, rejected like messages and tools.
            def enforce_canonical_thinking!(thinking)
              return thinking if thinking.nil?

              unless thinking.is_a?(Canonical::Thinking::Config)
                raise ArgumentError,
                      "provider thinking must be Canonical::Thinking::Config or nil, got #{thinking.class} — " \
                      'non-canonical thinking shapes must not cross the dispatch boundary'
              end
              thinking
            end

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
            end
          end
        end
      end
    end
  end
end
