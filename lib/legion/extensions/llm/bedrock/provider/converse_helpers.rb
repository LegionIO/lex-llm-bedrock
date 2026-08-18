# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # Converse API request formatting, response parsing, and stream handling.
          module ConverseHelpers
            private

            def converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                 guardrail_config: nil, thinking: nil)
              {
                model_id: self.class.inference_profile_id(model_id(model), geo_prefix: geo_prefix),
                messages: format_messages(messages.reject { |message| message.role == :system }),
                system: format_system(messages),
                inference_config: { temperature: temperature,
                                    max_tokens: max_tokens || model_max_tokens(model) }.compact,
                tool_config: format_tool_config(tools, tool_prefs),
                guardrail_config: guardrail_config,
                additional_model_request_fields: bedrock_additional_fields(thinking, model: model_id(model))
              }.compact
            end

            def bedrock_additional_fields(thinking, model:)
              fields = {}
              if thinking && !ThinkingModes.known_non_thinking?(model)
                fields[:thinking] = {
                  type: 'enabled',
                  budget_tokens: if thinking.is_a?(Hash)
                                   thinking[:budget_tokens] || thinking['budget_tokens'] ||
                                     thinking[:budget] || thinking['budget'] || 1024
                                 else
                                   1024
                                 end
                }
              end
              fields.empty? ? nil : fields
            end

            def format_messages(messages)
              total = messages.size
              formatted = messages.filter_map.with_index do |message, idx|
                blocks = build_content_blocks(message)
                next if blocks.empty?

                cache_blocks = should_cache_message?(idx, total) ? add_cache_control_to_blocks(blocks) : blocks
                { role: bedrock_role(message.role), content: cache_blocks }
              end
              consolidate_adjacent_roles(formatted)
            end

            def tool_result_blocks(message)
              return [] unless message.tool_result?

              [{
                tool_result: {
                  tool_use_id: message.tool_call_id,
                  content: [{ text: message.tool_results.to_s }]
                }
              }]
            end

            def should_cache_message?(index, total)
              return false if index == total - 1

              index < 4
            end

            def add_cache_control_to_blocks(blocks)
              blocks
            end

            def format_system(messages)
              system_messages = messages.select { |message| message.role == :system }
              system_text = system_messages.map { |message| content_text(message.content) }
              system_blocks(system_text.join("\n"))
            end

            def system_blocks(system)
              return nil if system.to_s.empty?

              [{ text: system }]
            end

            def bedrock_role(role)
              role == :assistant ? 'assistant' : 'user'
            end

            def build_content_blocks(message)
              return tool_result_blocks(message) if message.role == :tool

              return assistant_tool_use_blocks(message) if message.role == :assistant && message.tool_call?

              content_blocks(message.content)
            end

            def assistant_tool_use_blocks(message)
              blocks = []
              text = content_text(message.content)
              blocks << { text: text } if text && !text.strip.empty?

              calls = message.tool_calls.is_a?(Hash) ? message.tool_calls.values : Array(message.tool_calls)
              calls.each do |call|
                blocks << {
                  tool_use: {
                    tool_use_id: call.id,
                    name: call.name,
                    input: call.arguments || {}
                  }
                }
              end
              blocks
            end

            def content_blocks(content)
              raw = raw_content(content)
              return raw if raw

              return image_blocks(content) if content.respond_to?(:attachments) && !content.attachments.empty?

              text = content_text(content)
              return [] if text.strip.empty?

              [{ text: text }]
            end

            def image_blocks(content)
              blocks = []
              text = content_text(content)
              blocks << { text: text } if text.strip.present?

              content.attachments.each do |attachment|
                if attachment.is_a?(Legion::Extensions::Llm::Content::ImageAttachment)
                  blocks << format_image_attachment(attachment)
                end
              end
              blocks
            end

            def format_image_attachment(attachment)
              {
                image: {
                  format: image_format(attachment.format),
                  source: { bytes: attachment.data }
                }
              }
            end

            def image_format(fmt)
              case fmt.to_s.downcase
              when 'jpeg', 'jpg' then 'jpeg'
              when 'png' then 'png'
              when 'gif' then 'gif'
              when 'webp' then 'webp'
              end || 'jpeg'
            end

            def raw_content(content)
              return nil unless content.is_a?(Legion::Extensions::Llm::Content::Raw)

              Array(content.format)
            end

            def content_text(content)
              return content.text.to_s if content.respond_to?(:text)

              content.to_s
            end

            def format_tool_config(tools, tool_prefs)
              return nil if tools.empty?

              log.debug do
                "bedrock.provider.tools: formatting tools=#{tools.keys.map(&:to_s).sort.join(',')} " \
                  "tool_choice=#{tool_choice_label(tool_prefs)}"
              end
              {
                tools: tools.values.map { |tool| tool_definition_with_cache(tool) },
                tool_choice: tool_choice(tool_prefs)
              }.compact
            end

            def tool_definition_with_cache(tool)
              tool_definition(tool)
            end

            def tool_definition(tool)
              {
                tool_spec: {
                  name: tool.name,
                  description: tool.description,
                  input_schema: { json: tool_schema(tool) }
                }
              }
            end

            def tool_schema(tool)
              raw = if tool.respond_to?(:params_schema) && tool.params_schema
                      tool.params_schema
                    elsif tool.respond_to?(:parameters)
                      tool.parameters
                    end
              Legion::Extensions::Llm::Canonical::ToolDefinition.normalize_parameters(raw)
            end

            def tool_choice(tool_prefs)
              return nil unless tool_prefs

              choice = tool_prefs[:choice] || tool_prefs['choice']
              case choice
              when :auto, 'auto'
                { auto: {} }
              when :required, 'required'
                { any: {} }
              else
                { tool: { name: choice.to_s } }
              end
            end

            def tool_choice_label(tool_prefs)
              return 'none' unless tool_prefs

              (tool_prefs[:choice] || tool_prefs['choice'] || 'unspecified').to_s
            end

            def parse_converse_response(response, fallback_model)
              output = value(response, :output)
              message = value(output, :message)
              content_blocks = value(message, :content)
              usage = value(response, :usage) || {}
              additional_fields = value(response, :additional_model_response_fields)

              msg_attrs = {
                role: :assistant,
                content: text_from(content_blocks),
                model_id: fallback_model,
                tool_calls: parse_tool_calls(content_blocks),
                input_tokens: value(usage, :input_tokens),
                output_tokens: value(usage, :output_tokens),
                cached_tokens: cache_read_tokens(usage),
                cache_creation_tokens: cache_write_tokens(usage),
                raw: normalize_response(response)
              }

              thinking_text = extract_thinking_from_content(content_blocks) ||
                              (additional_fields ? extract_thinking_from_fields(additional_fields) : nil)
              msg_attrs[:thinking] = thinking_text if thinking_text

              Legion::Extensions::Llm::Message.new(**msg_attrs)
            end

            def extract_thinking_from_content(content_blocks)
              return nil unless content_blocks

              Array(content_blocks).each do |block|
                reasoning = value(block, :reasoning)
                next if reasoning.nil?

                text = if reasoning.is_a?(Hash)
                         reasoning[:text] || reasoning['text']
                       else
                         value(reasoning, :text)
                       end
                return text.to_s unless text.to_s.empty?
              end
              nil
            end

            def extract_thinking_from_fields(additional_fields)
              thinking = additional_fields[:thinking] || additional_fields['thinking']
              return nil unless thinking.is_a?(Hash)

              content = thinking[:text] || thinking['text'] ||
                        thinking[:reasoning_text] || thinking['reasoningText'] ||
                        thinking[:reasoning] || thinking['reasoning'] ||
                        reasoning_content_text(thinking)
              content.to_s unless content.to_s.empty?
            end

            def reasoning_content_text(thinking)
              rc = thinking[:reasoningContent] || thinking['reasoningContent']
              return nil unless rc.is_a?(Hash)

              chunk = rc[:chunk] || rc['chunk']
              if chunk.is_a?(Hash)
                chunk[:text] || chunk['text']
              else
                rc[:text] || rc['text']
              end
            end

            def text_from(content)
              Array(content).filter_map { |block| value(block, :text) }.join
            end

            def parse_tool_calls(content)
              calls = Array(content).filter_map { |block| value(block, :tool_use) }
              return nil if calls.empty?

              calls.to_h do |call|
                name = value(call, :name)
                [
                  value(call, :tool_use_id) || name,
                  Legion::Extensions::Llm::ToolCall.new(id: value(call, :tool_use_id) || name, name: name,
                                                        arguments: value(call, :input) || {})
                ]
              end
            end

            def cache_read_tokens(usage)
              return nil if usage.nil?

              value(usage, :cache_read_input_tokens) || value(usage, 'cache_read_input_tokens')
            end

            def cache_write_tokens(usage)
              return nil if usage.nil?

              value(usage, :cache_creation_input_tokens) || value(usage, 'cache_creation_input_tokens')
            end

            def stream_converse(request, fallback_model)
              state = { accumulated: +'', thinking: +'', final_usage: nil, stop_reason: nil,
                        tool_use_blocks: [], current_tool_use: nil, in_thinking: false,
                        raw_events: [] }

              log.debug do
                "bedrock.provider.stream_converse: starting model=#{fallback_model} " \
                  "tools=#{state[:tool_use_blocks].size}"
              end

              dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)

              runtime_client.converse_stream(**request) do |stream|
                wire_stream_handlers(stream, state, fallback_model) { |chunk| yield chunk if block_given? }

                next unless dump_path

                stream.on_content_block_start_event do |e|
                  state[:raw_events] << { event: 'content_block_start', data: safe_event_data(e) }
                end
                stream.on_content_block_delta_event do |e|
                  state[:raw_events] << { event: 'content_block_delta', data: safe_event_data(e) }
                end
                stream.on_content_block_stop_event do |e|
                  state[:raw_events] << { event: 'content_block_stop', data: safe_event_data(e) }
                end
                stream.on_message_start_event do |e|
                  state[:raw_events] << { event: 'message_start', data: safe_event_data(e) }
                end
                stream.on_message_stop_event do |e|
                  state[:raw_events] << { event: 'message_stop', data: safe_event_data(e) }
                end
                stream.on_metadata_event { |e| state[:raw_events] << { event: 'metadata', data: safe_event_data(e) } }
              end

              if dump_path && state[:raw_events].any?
                dump_stream_events(state[:raw_events], dump_path,
                                   'bedrock_stream')
              end

              log.debug do
                "bedrock.provider.stream_converse: completed model=#{fallback_model} " \
                  "accumulated_length=#{state[:accumulated].length} thinking_length=#{state[:thinking].length} " \
                  "tool_use_blocks=#{state[:tool_use_blocks].size} stop_reason=#{state[:stop_reason]}"
              end

              build_stream_message(state, fallback_model)
            end

            def dump_stream_events(events, dump_path, prefix)
              dump_file = File.join(dump_path, "#{prefix}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
              File.write(dump_file, Legion::JSON.pretty_generate(events))
              log.debug { "bedrock.provider.stream_converse: #{events.size} raw events dumped to #{dump_file}" }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'bedrock.provider.dump_stream_events')
            end

            def build_stream_message(state, fallback_model)
              msg_attrs = {
                role: :assistant,
                content: state[:accumulated],
                model_id: fallback_model,
                tool_calls: build_stream_tool_calls(state[:tool_use_blocks]),
                input_tokens: value(state[:final_usage], :input_tokens),
                output_tokens: value(state[:final_usage], :output_tokens),
                cached_tokens: cache_read_tokens(state[:final_usage]),
                cache_creation_tokens: cache_write_tokens(state[:final_usage]),
                stop_reason: state[:stop_reason]
              }
              msg_attrs[:thinking] = state[:thinking] unless state[:thinking].empty?
              Legion::Extensions::Llm::Message.new(**msg_attrs)
            end

            def wire_stream_handlers(stream, state, fallback_model, &)
              wire_block_start(stream, state)
              wire_block_delta(stream, state, fallback_model, &)
              wire_block_stop(stream, state)
              wire_message_stop(stream, state)
              stream.on_metadata_event { |event| state[:final_usage] = value(event, :usage) }
            end

            def wire_block_start(stream, state)
              return unless stream.respond_to?(:on_content_block_start_event)

              stream.on_content_block_start_event do |event|
                start = value(event, :start)

                if value(start, :thinking) || value(start, :reasoning)
                  state[:in_thinking] = true
                  next
                end

                state[:in_thinking] = false
                tool_start = value(start, :tool_use) if start
                next unless tool_start

                state[:current_tool_use] = {
                  tool_use_id: value(tool_start, :tool_use_id),
                  name: value(tool_start, :name),
                  input_json: +''
                }
              end
            end

            def wire_block_delta(stream, state, fallback_model)
              stream.on_content_block_delta_event do |event|
                delta = value(event, :delta)
                text = value(delta, :text) ||
                       value(value(delta, :reasoning), :text) ||
                       value(value(delta, :thinking), :text)
                if text
                  if state[:in_thinking]
                    state[:thinking] << text
                  else
                    state[:accumulated] << text
                    if block_given?
                      yield Legion::Extensions::Llm::Chunk.new(role: :assistant, content: text,
                                                               model_id: fallback_model)
                    end
                  end
                end

                tool_input = value(delta, :tool_use)
                next unless tool_input && state[:current_tool_use]

                input_chunk = value(tool_input, :input)
                state[:current_tool_use][:input_json] << input_chunk.to_s if input_chunk
              end
            end

            def wire_block_stop(stream, state)
              return unless stream.respond_to?(:on_content_block_stop_event)

              stream.on_content_block_stop_event do |_event|
                next unless state[:current_tool_use]

                state[:tool_use_blocks] << state[:current_tool_use]
                state[:current_tool_use] = nil
              end
            end

            def wire_message_stop(stream, state)
              return unless stream.respond_to?(:on_message_stop_event)

              stream.on_message_stop_event do |event|
                state[:stop_reason] = value(event, :stop_reason)
              end
            end

            def build_stream_tool_calls(tool_use_blocks)
              return nil if tool_use_blocks.empty?

              tool_use_blocks.to_h do |block|
                input = begin
                  Legion::JSON.load(block[:input_json])
                rescue Legion::JSON::ParseError => e
                  handle_exception(e, level: :warn, handled: true,
                                      operation: 'bedrock.provider.build_stream_tool_calls')
                  {}
                end
                name = block[:name]
                id = block[:tool_use_id] || name
                [id, Legion::Extensions::Llm::ToolCall.new(id: id, name: name, arguments: input)]
              end
            end

            def consolidate_adjacent_roles(messages)
              return messages if messages.size < 2

              messages.each_with_object([]) do |msg, result|
                if result.last && result.last[:role] == msg[:role]
                  result.last[:content] = Array(result.last[:content]) + Array(msg[:content])
                else
                  result << msg
                end
              end
            end
          end
        end
      end
    end
  end
end
