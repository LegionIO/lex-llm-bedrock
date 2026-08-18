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
          module InvokeModelHelpers
            private

            def anthropic_model?(model_id)
              return false unless model_id

              model_id.to_s.start_with?('anthropic.', 'us.anthropic.', 'eu.anthropic.', 'ap.anthropic.')
            end

            def invoke_model_chat(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                  thinking:, _params: nil, **_rest)
              mid = model_id(model)
              body = build_invoke_model_body(
                messages: messages, model: mid, temperature: temperature, max_tokens: max_tokens,
                tools: tools, tool_prefs: tool_prefs, thinking: thinking
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

              dump_invoke_model_response(body_str, 'bedrock_invoke_chat')

              parsed_body = Legion::JSON.parse(body_str, symbolize_names: false)
              parse_invoke_model_response_hash(parsed_body, mid)
            end

            def invoke_model_stream(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                    thinking:, _params: nil, **_rest, &)
              mid = model_id(model)
              body = build_invoke_model_body(
                messages: messages, model: mid, temperature: temperature, max_tokens: max_tokens,
                tools: tools, tool_prefs: tool_prefs, thinking: thinking, streaming: true
              )
              log.debug { "bedrock.provider.invoke_model_stream: model=#{mid} thinking=#{thinking.inspect}" }

              state = { accumulated: +'', thinking: +'', final_usage: nil, stop_reason: nil,
                        tool_use_blocks: [], current_tool_use: nil, in_thinking: false, raw_events: [] }

              dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)

              runtime_client.invoke_model_with_response_stream(
                model_id: self.class.inference_profile_id(mid, geo_prefix: geo_prefix),
                content_type: 'application/json',
                accept: 'application/json',
                body: Legion::JSON.generate(body)
              ) do |stream|
                wire_invoke_model_response_stream(stream, state, mid, dump_path, &)
              end

              dump_invoke_model_stream_events(state[:raw_events], dump_path)

              usage = state[:final_usage] || {}
              msg_attrs = {
                role: :assistant,
                content: state[:accumulated],
                model_id: mid,
                tool_calls: build_stream_tool_calls(state[:tool_use_blocks]),
                input_tokens: usage.fetch(:input_tokens, 0) || usage.fetch('input_tokens', 0),
                output_tokens: usage.fetch(:output_tokens, 0) || usage.fetch('output_tokens', 0),
                cached_tokens: usage.fetch(:cache_read_input_tokens, nil) ||
                               usage.fetch('cache_read_input_tokens', nil),
                cache_creation_tokens: usage.fetch(:cache_creation_input_tokens, nil) ||
                                       usage.fetch('cache_creation_input_tokens', nil),
                stop_reason: state[:stop_reason]
              }
              msg_attrs[:thinking] = state[:thinking] unless state[:thinking].empty?
              Legion::Extensions::Llm::Message.new(**msg_attrs)
            end

            def wire_invoke_model_response_stream(stream, state, mid, dump_path, &)
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

                  state[:raw_events] << { event: raw_event['type'] || 'unknown', data: raw_event } if dump_path
                  handle_invoke_model_stream_json(raw_event, state, mid, &)
                end
              rescue Legion::JSON::ParseError => e
                handle_exception(e, level: :warn, handled: true,
                                    operation: 'bedrock.provider.invoke_model_stream.chunk_decode')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false,
                                    operation: 'bedrock.provider.invoke_model_stream.chunk_event')
                raise
              end

              stream.on_error_event do |event|
                log.warn do
                  "bedrock.provider.invoke_model_stream: error event ivars=#{event.instance_variables.inspect}"
                end
              end

              stream.on_internal_server_exception_event do |event|
                log.warn do
                  'bedrock.provider.invoke_model_stream: internal_server_exception ' \
                    "ivars=#{event.instance_variables.inspect}"
                end
              end

              stream.on_model_stream_error_exception_event do |event|
                log.warn do
                  'bedrock.provider.invoke_model_stream: model_stream_error ' \
                    "ivars=#{event.instance_variables.inspect}"
                end
              end
            end

            def build_invoke_model_body(messages:, temperature:, max_tokens:, tools:, tool_prefs:, thinking:, **rest)
              system_content = extract_invoke_model_system(messages, system: rest[:system])
              body = {
                max_tokens: max_tokens || 4096,
                messages: format_invoke_model_messages(messages),
                anthropic_version: 'bedrock-2023-05-31'
              }
              body[:system] = system_content if system_content
              body[:temperature] = temperature if temperature
              if tools && !tools.empty?
                tool_format = format_invoke_model_tools(tools, tool_prefs)
                body[:tools] = tool_format[:tools]
                body[:tool_choice] = tool_format[:tool_choice] if tool_format[:tool_choice]
              end
              if thinking
                thinking_cfg = invoke_model_thinking(model: rest[:model] || model_id(rest[:model]), thinking: thinking)
                body[:thinking] = thinking_cfg if thinking_cfg
              end
              body
            end

            def extract_invoke_model_system(messages, system: nil)
              parts = []
              parts << system.to_s unless system.to_s.empty?
              messages.each do |msg|
                role = msg.respond_to?(:role) ? msg.role.to_s : (msg[:role] || msg['role']).to_s
                next unless role == 'system'

                content = msg.respond_to?(:content) ? msg.content : (msg[:content] || msg['content'])
                text = content.is_a?(Array) ? content.filter_map { |b| b[:text] || b['text'] }.join("\n") : content.to_s
                parts << text unless text.empty?
              end
              return nil if parts.empty?

              parts.map { |t| { type: 'text', text: t } }
            end

            # Emit the thinking wire shape the model actually supports.
            # Budgeted-thinking Claude models get { type: 'enabled', budget_tokens: N }.
            # Every other model returns nil so the caller OMITS the thinking field —
            # Bedrock rejects { type: 'adaptive' } with a ValidationException (HTTP 500).
            def invoke_model_thinking(model:, thinking:)
              mid = model_id(model)
              return nil if ThinkingModes.known_non_thinking?(mid)

              budget = if thinking.is_a?(Hash)
                         thinking[:budget_tokens] || thinking['budget_tokens'] ||
                           thinking[:budget] || thinking['budget']
                       end
              { type: 'enabled', budget_tokens: budget }.compact
            end

            def format_invoke_model_messages(messages)
              formatted = messages.filter_map do |msg|
                role = msg.respond_to?(:role) ? msg.role.to_s : (msg[:role] || msg['role']).to_s
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
              content = msg.respond_to?(:content) ? msg.content : (msg[:content] || msg['content'])
              return [] if content.nil?

              if content.is_a?(String)
                [{ type: 'text', text: content }]
              elsif content.is_a?(Array)
                content.filter_map do |block|
                  type = (block[:type] || block['type']).to_s
                  next { type: 'text', text: block[:text] || block['text'] } if type == 'text'

                  block
                end
              else
                [{ type: 'text', text: content.to_s }]
              end
            end

            def format_invoke_model_tool_result(msg)
              tool_call_id = if msg.respond_to?(:tool_call_id)
                               msg.tool_call_id
                             else
                               msg[:tool_call_id] || msg['tool_call_id']
                             end
              content = msg.respond_to?(:tool_results) ? msg.tool_results.to_s : (msg[:content] || msg['content']).to_s
              [{ type: 'tool_result', tool_use_id: tool_call_id, content: [{ type: 'text', text: content }] }]
            end

            def format_invoke_model_assistant(msg)
              blocks = []
              text = msg.respond_to?(:content) ? msg.content : (msg[:content] || msg['content'])
              blocks << { type: 'text', text: text.to_s } unless text.to_s.strip.empty?

              tool_calls = msg.respond_to?(:tool_calls) ? msg.tool_calls : (msg[:tool_calls] || msg['tool_calls'] || {})
              call_array = tool_calls.is_a?(Hash) ? tool_calls.values : Array(tool_calls)

              call_array.each do |call|
                blocks << {
                  type: 'tool_use',
                  id: call.respond_to?(:id) ? call.id : call[:id] || call['id'],
                  name: call.respond_to?(:name) ? call.name : call[:name] || call['name'],
                  input: if call.respond_to?(:arguments)
                           call.arguments
                         else
                           call[:arguments] || call['arguments'] || {}
                         end
                }
              end
              blocks
            end

            def format_invoke_model_tools(tools, tool_prefs)
              tool_list = tools.values.map do |tool|
                raw_schema = tool[:params_schema] || tool['params_schema'] ||
                             tool[:parameters] || tool['parameters']
                {
                  name: tool[:name] || tool['name'],
                  description: tool[:description] || tool['description'] || '',
                  input_schema: Legion::Extensions::Llm::Canonical::ToolDefinition.normalize_parameters(raw_schema)
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

            def build_invoke_model_message(body, mid)
              content_blocks = body['content'] || []

              text_parts    = content_blocks.filter_map { |b| b['text'] if b['type'] == 'text' }.join
              thinking_text = content_blocks.filter_map { |b| b['thinking'] if b['type'] == 'thinking' }.join
              tool_calls_raw = content_blocks.select { |b| b['type'] == 'tool_use' }

              tc = tool_calls_raw.to_h do |tc_block|
                [tc_block['id'], Legion::Extensions::Llm::ToolCall.new(
                  id: tc_block['id'], name: tc_block['name'], arguments: tc_block['input'] || {}
                )]
              end

              usage = body['usage'] || {}
              msg_attrs = {
                role: :assistant,
                content: text_parts,
                model_id: mid,
                tool_calls: tc.empty? ? nil : tc,
                input_tokens: usage['input_tokens'] || 0,
                output_tokens: usage['output_tokens'] || 0,
                cached_tokens: usage['cache_read_input_tokens'],
                cache_creation_tokens: usage['cache_creation_input_tokens']
              }
              msg_attrs[:thinking] = thinking_text unless thinking_text.empty?
              Legion::Extensions::Llm::Message.new(**msg_attrs)
            end

            def handle_invoke_model_stream_json(event_json, state, model_id)
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
                handle_invoke_model_delta(event_json['delta'] || {}, state, model_id) { |c| yield c if block_given? }
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

            def handle_invoke_model_delta(delta, state, model_id)
              case delta['type'].to_s
              when 'thinking_delta'
                text = delta['thinking'] || ''
                state[:thinking] << text
                if block_given? && !text.empty?
                  yield Legion::Extensions::Llm::Chunk.new(
                    role: :assistant, content: '', model_id: model_id,
                    thinking: { content: text, enabled: true }
                  )
                end
              when 'text_delta'
                text = delta['text'] || ''
                state[:accumulated] << text
                if block_given?
                  yield Legion::Extensions::Llm::Chunk.new(role: :assistant, content: text,
                                                           model_id: model_id)
                end
              when 'input_json_delta'
                partial = delta['partial_json'] || ''
                state[:current_tool_use][:input_json] << partial
                if block_given? && !partial.empty? && state[:current_tool_use]
                  yield Legion::Extensions::Llm::Chunk.new(
                    role: :assistant, content: '', model_id: model_id,
                    tool_calls: {
                      state[:current_tool_use][:tool_use_id].to_sym =>
                        Legion::Extensions::Llm::ToolCall.new(
                          id: state[:current_tool_use][:tool_use_id],
                          name: state[:current_tool_use][:name],
                          arguments: partial
                        )
                    }
                  )
                end
              end
            end

            def dump_invoke_model_response(body_str, prefix)
              dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)
              return unless dump_path

              dump_file = File.join(dump_path, "#{prefix}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
              File.write(dump_file, body_str)
              log.debug { "bedrock.provider.invoke_model: raw response dumped to #{dump_file}" }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'bedrock.provider.dump_invoke_model_response')
            end

            def dump_invoke_model_stream_events(raw_events, dump_path)
              return unless dump_path && raw_events.any?

              dump_file = File.join(dump_path,
                                    "bedrock_invoke_stream_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
              File.write(dump_file, Legion::JSON.pretty_generate(raw_events))
              log.debug do
                "bedrock.provider.invoke_model_stream: #{raw_events.size} raw events dumped to #{dump_file}"
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'bedrock.provider.dump_invoke_model_stream_events')
            end
          end
        end
      end
    end
  end
end
