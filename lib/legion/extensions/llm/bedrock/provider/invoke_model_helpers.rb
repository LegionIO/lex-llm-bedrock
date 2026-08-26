# frozen_string_literal: true

require 'zlib'

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # Native invoke_model (Anthropic Messages API payload) path used for
          # thinking-enabled and tool-call requests on Anthropic models where the
          # Converse API silently drops the required fields.
          #
          # 0.8.0 renderer/parser law (08 R1-R4): render FROM canonical values;
          # parse TO canonical types. Dialect tolerance (Anthropic event wire)
          # lives in these helpers only.
          module InvokeModelHelpers
            private

            # B5: system arrives as the folded member value (the dispatch
            # edge folded system-role messages); messages are system-free.
            def invoke_model_chat(messages:, model:, tools: {}, tool_prefs: nil,
                                  system: nil, thinking: nil, params: nil)
              mid = model_id(model)
              body = build_invoke_model_body(
                messages: messages, model: mid, tools: tools, tool_prefs: tool_prefs,
                system: system, thinking: thinking, params: params
              )
              log.debug { "bedrock.provider.invoke_model_chat: model=#{mid} thinking=#{thinking.inspect}" }

              response = runtime_client.invoke_model(
                model_id: self.class.inference_profile_id(mid, geo_prefix: geo_prefix),
                content_type: 'application/json',
                accept: 'application/json',
                body: Legion::JSON.generate(body)
              )

              body_raw = value(response, :body)
              body_raw = body_raw.read   if body_raw.respond_to?(:read)
              body_raw = body_raw.string if body_raw.respond_to?(:string)
              body_str = body_raw.to_s

              parsed_body = Legion::JSON.parse(body_str, symbolize_names: false)
              parse_invoke_model_response_hash(parsed_body, mid)
            end

            def invoke_model_stream(messages:, model:, tools: {}, tool_prefs: nil, system: nil,
                                    thinking: nil, params: nil, &)
              mid = model_id(model)
              body = build_invoke_model_body(
                messages: messages, model: mid, tools: tools, tool_prefs: tool_prefs,
                system: system, thinking: thinking, params: params
              )
              log.debug { "bedrock.provider.invoke_model_stream: model=#{mid} thinking=#{thinking.inspect}" }

              request_id = params&.metadata&.[](:request_id)
              state = { accumulated: +'', thinking: +'', final_usage: nil, stop_reason: nil,
                        tool_use_blocks: [], current_tool_use: nil, in_thinking: false,
                        stream_error: nil, request_id: request_id }

              runtime_client.invoke_model_with_response_stream(
                model_id: self.class.inference_profile_id(mid, geo_prefix: geo_prefix),
                content_type: 'application/json',
                accept: 'application/json',
                body: Legion::JSON.generate(body)
              ) do |stream|
                wire_invoke_model_response_stream(stream, state, &)
              end

              # B7: an explicit provider error event is a dispatch failure —
              # raised before any done chunk. B6: the strict stream-end tool
              # parse happens before the done chunk for the same reason.
              raise_stream_error!(state, dialect: 'invoke_model')
              tool_calls = build_stream_tool_calls(state[:tool_use_blocks])

              yield done_chunk(state, request_id: state[:request_id]) if block_given?
              build_stream_response(state, mid, tool_calls:)
            end

            def wire_invoke_model_response_stream(stream, state, &)
              stream.on_chunk_event do |event|
                raw = event.respond_to?(:bytes) ? event.bytes : nil
                raw = raw.read if raw.respond_to?(:read)
                next unless raw&.length&.positive?

                raw = Zlib::GzipReader.wrap(StringIO.new(raw), &:read) if raw.byteslice(0, 2) == "\x1f\x8b"
                text = raw.force_encoding('UTF-8')
                text.lines.each do |line|
                  line = line.strip
                  next if line.empty?

                  raw_event = Legion::JSON.parse(line, symbolize_names: false)
                  next unless raw_event.is_a?(Hash)

                  handle_invoke_model_stream_json(raw_event, state, &)
                end
              rescue Legion::JSON::ParseError => e
                handle_exception(e, level: :warn, handled: true,
                                    operation: 'bedrock.provider.invoke_model_stream.chunk_decode')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false,
                                    operation: 'bedrock.provider.invoke_model_stream.chunk_event')
                raise
              end

              # B7: explicit provider error events are dispatch failures —
              # recorded and raised before any done chunk (the old log-only
              # handlers let a truncated stream complete as success).
              stream.on_error_event do |event|
                record_stream_error(state, event: event, type: 'error')
              end

              stream.on_internal_server_exception_event do |event|
                record_stream_error(state, event: event, type: 'internal_server_exception')
              end

              stream.on_model_stream_error_exception_event do |event|
                record_stream_error(state, event: event, type: 'model_stream_error_exception')
              end
            end

            # 08 R1/F4: the Anthropic-wire renderer receives canonical values —
            # max_tokens/temperature are read from the Canonical::Params members.
            # B18: max_tokens has one owner (RenderDefaults). B2: the thinking
            # wire shape has one builder (ThinkingModes) — the Hash-only read
            # that emitted a budget-less { type: 'enabled' } (the Bedrock
            # ValidationException shape) is deleted.
            def build_invoke_model_body(messages:, model:, tools: {}, tool_prefs: nil, system: nil,
                                        thinking: nil, params: nil)
              effective_mt = RenderDefaults.max_tokens(params, target: :invoke_model)
              body = {
                max_tokens: effective_mt,
                messages: format_invoke_model_messages(messages),
                anthropic_version: 'bedrock-2023-05-31'
              }
              body[:system] = [{ type: 'text', text: system }] if system
              body[:temperature] = params&.temperature if params&.temperature
              if tools && !tools.empty?
                tool_format = format_invoke_model_tools(tools, tool_prefs)
                body[:tools] = tool_format[:tools]
                body[:tool_choice] = tool_format[:tool_choice] if tool_format[:tool_choice]
              end
              thinking_cfg = ThinkingModes.thinking_wire(
                thinking:, model_id: model, params:, effective_max_tokens: effective_mt
              )
              body[:thinking] = thinking_cfg if thinking_cfg
              body
            end

            def format_invoke_model_messages(messages)
              formatted = messages.filter_map do |msg|
                role = msg.role.to_s
                next if role == 'system'

                content = case role
                          when 'tool'
                            format_invoke_model_tool_result(msg)
                          when 'assistant'
                            format_invoke_model_assistant(msg)
                          else
                            format_invoke_model_content(msg)
                          end

                next if content.nil? || (content.is_a?(Array) && content.empty?)

                { role: role == 'tool' ? 'user' : role, content: content }
              end
              consolidate_adjacent_roles(formatted)
            end

            def format_invoke_model_content(msg)
              content = msg.content
              return [] if content.nil?

              case content
              when ::String
                [{ type: 'text', text: content }]
              when ::Array
                content.filter_map { |block| invoke_user_content_block(block) }
              when Canonical::ContentBlock
                block = invoke_user_content_block(content)
                block ? [block] : []
              else
                [{ type: 'text', text: content.to_s }]
              end
            end

            # One Anthropic-wire user-content block from a canonical block:
            # text and image render; other block types have no Anthropic
            # user-content spelling and do not render.
            def invoke_user_content_block(block)
              return nil unless block.is_a?(Canonical::ContentBlock)

              if block.text?
                text = block.text.to_s
                return nil if text.strip.empty?

                { type: 'text', text: text }
              elsif block.type == :image
                {
                  type: 'image',
                  source: {
                    type: 'base64',
                    media_type: block.media_type,
                    data: block.data
                  }
                }
              end
            end

            def format_invoke_model_tool_result(msg)
              tool_call_id = msg.tool_call_id
              content = msg.text.to_s
              [{ type: 'tool_result', tool_use_id: tool_call_id, content: [{ type: 'text', text: content }] }]
            end

            def format_invoke_model_assistant(msg)
              blocks = []
              text = msg.text.to_s
              blocks << { type: 'text', text: text } unless text.strip.empty?

              Array(msg.tool_calls).each do |call|
                blocks << {
                  type: 'tool_use',
                  id: call.id,
                  name: call.name,
                  input: call.arguments || {}
                }
              end
              blocks
            end

            # B3: canonical-in — the dispatch funnel (enforce_canonical_tools!)
            # guarantees Canonical::ToolDefinition values; the Hash tolerance
            # that carried poison to the wire (load-bearing for the fleet
            # crash class) is deleted. parameters is normalized at
            # ToolDefinition construction.
            def format_invoke_model_tools(tools, tool_prefs)
              tool_list = tools.values.map do |tool|
                {
                  name: tool.name,
                  description: tool.description,
                  input_schema: tool.parameters
                }
              end

              result = { tools: tool_list }
              if tool_prefs
                choice = tool_prefs[:choice] || tool_prefs['choice']
                result[:tool_choice] = if %i[required].include?(choice) || choice == 'required'
                                         { type: 'any' }
                                       elsif choice.to_s != 'auto' && !choice.to_s.empty?
                                         { type: 'tool', name: choice.to_s }
                                       else
                                         { type: 'auto' }
                                       end
              end
              result
            end

            def parse_invoke_model_response(response, mid)
              body_raw = value(response, :body)
              body_raw = body_raw.read   if body_raw.respond_to?(:read)
              body_raw = body_raw.string if body_raw.respond_to?(:string)
              body = Legion::JSON.parse(body_raw, symbolize_names: false)
              build_invoke_model_message(body, mid)
            end

            def parse_invoke_model_response_hash(body, mid)
              build_invoke_model_message(body, mid)
            end

            # 08 R2: the single sync parse boundary — the gem's canonical
            # translator (ResponseParsing) turns the wire hash into
            # Canonical::Response.
            def build_invoke_model_message(body, mid)
              translator.parse_response(body, model: mid)
            end

            def handle_invoke_model_stream_json(event_json, state)
              case event_json['type']
              when 'message_start'
                state[:final_usage] = (event_json['message'] || {})['usage'] || {}
              when 'content_block_start'
                block = event_json['content_block'] || {}
                block_type = block['type'].to_s
                state[:in_thinking] = (block_type == 'thinking')
                if block_type == 'tool_use'
                  state[:current_tool_use] = { tool_use_id: block['id'], name: block['name'], input_json: +'' }
                elsif block_type != 'thinking'
                  state[:in_thinking] = false
                end
              when 'content_block_delta'
                handle_invoke_model_delta(event_json['delta'] || {}, state) { |c| yield c if block_given? }
              when 'content_block_stop'
                if state[:current_tool_use]
                  state[:tool_use_blocks] << state[:current_tool_use]
                  state[:current_tool_use] = nil
                end
              when 'message_delta'
                state[:stop_reason] = (event_json['delta'] || {})['stop_reason']
              end
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false,
                                  operation: 'bedrock.provider.invoke_model_stream_json')
              raise
            end

            def handle_invoke_model_delta(delta, state)
              request_id = state[:request_id]
              case delta['type'].to_s
              when 'thinking_delta'
                text = delta['thinking'] || ''
                state[:thinking] << text
                yield Canonical::Chunk.thinking_delta(delta: text, request_id:) if block_given? && !text.empty?
              when 'text_delta'
                text = delta['text'] || ''
                state[:accumulated] << text
                yield Canonical::Chunk.text_delta(delta: text, request_id:) if block_given?
              when 'input_json_delta'
                partial = delta['partial_json'] || ''
                state[:current_tool_use][:input_json] << partial
                if block_given? && !partial.empty? && state[:current_tool_use]
                  # Canonical chunk fragment law: the wire fragment (String
                  # arguments) travels on the chunk; the assembled JSON is
                  # parsed once, at stream end (10 U2).
                  yield Canonical::Chunk.tool_call_delta(
                    tool_call: {
                      id: state[:current_tool_use][:tool_use_id],
                      name: state[:current_tool_use][:name],
                      arguments: partial
                    },
                    request_id:
                  )
                end
              end
            end
          end
        end
      end
    end
  end
end
