# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Translator
          # Converse and invoke_model response parsing helpers.
          module ResponseParsing
            private

            def parse_converse_response(wire, model)
              output   = read_from(wire, 'output', :output)
              message  = read_from(output, 'message', :message)
              content  = read_from(message, 'content', :content)
              usage_raw = read_from(wire, 'usage', :usage) || {}
              additional = read_from(wire, 'additional_model_response_fields',
                                     :additional_model_response_fields)

              text = extract_text_from(content)
              thinking_text = extract_thinking_from_content(content) || extract_thinking_from_fields(additional)
              thinking_obj = if thinking_text.to_s.empty?
                               nil
                             else
                               Canonical::Thinking.build(content: thinking_text.to_s,
                                                         signature: nil)
                             end

              Canonical::Response.build(
                text: text,
                thinking: thinking_obj,
                tool_calls: extract_tool_calls_from(content),
                usage: parse_usage(usage_raw),
                stop_reason: map_stop_reason(extract_stop_reason_from(message)),
                model: model,
                routing: {},
                metadata: {}
              )
            end

            def extract_text_from(content_blocks)
              Array(content_blocks).filter_map { |block| read_from(block, 'text', :text).to_s }.join
            end

            def extract_thinking_from_content(content_blocks)
              Array(content_blocks).each do |block|
                reasoning = read_from(block, 'reasoning', :reasoning)
                next if reasoning.nil?

                text = if reasoning.is_a?(Hash)
                         reasoning[:text] || reasoning['text']
                       elsif reasoning.respond_to?(:text)
                         begin
                           reasoning.text
                         rescue StandardError => e
                           handle_exception(e, level: :debug, handled: true,
                                               operation: 'bedrock.translator.extract_thinking_from_content')
                           nil
                         end
                       else
                         safe_key_read(reasoning, :text)
                       end
                return text if text && !text.to_s.empty?
              end
              nil
            end

            def extract_thinking_from_fields(additional)
              return nil unless additional.is_a?(Hash)

              thinking = additional[:thinking] || additional['thinking']
              return nil unless thinking.is_a?(Hash)

              text = thinking[:text] || thinking['text'] ||
                     thinking[:reasoningText] || thinking['reasoningText'] ||
                     thinking[:reasoning] || thinking['reasoning'] ||
                     resolve_reasoning_content(thinking)
              text if text && !text.to_s.empty?
            end

            def resolve_reasoning_content(thinking)
              rc = thinking[:reasoningContent] || thinking['reasoningContent']
              return nil unless rc.is_a?(Hash)

              chunk = rc[:chunk] || rc['chunk']
              if chunk.is_a?(Hash)
                chunk[:text] || chunk['text']
              else
                rc[:text] || rc['text']
              end
            end

            def extract_tool_calls_from(content_blocks)
              calls = Array(content_blocks).filter_map { |block| read_from(block, 'tool_use', :tool_use) }
              return [] if calls.empty?

              calls.map do |call|
                tc_id = safe_read(call, :tool_use_id, 'tool_use_id', '')
                name  = safe_read(call, :name, 'name', '')
                input = safe_read(call, :input, 'input', {})
                input = parse_tool_input(input)
                Canonical::ToolCall.build(id: tc_id.to_s, name: name.to_s, arguments: input,
                                          source: :client, status: :pending)
              end
            end

            # B6: the ONE shared strict arguments parser (10 U2) — invalid or
            # non-object JSON raises; the rescue-to-{} policy is deleted. A
            # wire Hash passes through (already parsed by the transport).
            def parse_tool_input(input)
              return input if input.is_a?(Hash)

              Legion::Extensions::Llm::Responses::ToolArguments.parse!(input)
            end

            def extract_stop_reason_from(message)
              return nil unless message

              read_from(message, 'stop_reason', :stop_reason)
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true,
                                  operation: 'bedrock.translator.extract_stop_reason_from')
              nil
            end

            def parse_invoke_model_response(wire, model)
              content = wire['content'] || wire[:content] || []
              usage_raw = wire['usage'] || wire[:usage] || {}
              stop_raw  = wire['stop_reason'] || wire[:stop_reason]

              text = Array(content).filter_map { |b| b['type'] == 'text' ? b['text'] : nil }.join

              thinking_parts = Array(content).select { |b| b['type'] == 'thinking' }
              thinking_obj = if thinking_parts.any?
                               tp = thinking_parts.last
                               Canonical::Thinking.build(content: tp['thinking'], signature: tp['signature'])
                             end

              tool_calls_list = Array(content).select { |b| b['type'] == 'tool_use' }.map do |b|
                args = b['input'] || {}
                args = parse_tool_input(args)
                Canonical::ToolCall.build(
                  id: b['id'], name: b['name'], arguments: args.is_a?(Hash) ? args : {},
                  source: :client, status: :pending
                )
              end

              Canonical::Response.build(
                text: text,
                thinking: thinking_obj,
                tool_calls: tool_calls_list,
                usage: parse_usage(usage_raw),
                stop_reason: map_stop_reason(stop_raw),
                model: model,
                routing: {},
                metadata: {}
              )
            end
          end
        end
      end
    end
  end
end
