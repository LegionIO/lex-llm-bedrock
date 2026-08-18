# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Translator
          # Message rendering helpers for both Converse API and invoke_model wire formats.
          module MessageRendering
            private

            def render_converse_messages(messages)
              return [] unless messages

              messages.filter_map do |msg|
                next if msg.role == :system

                blocks = convers_content_for(msg)
                next if blocks.empty?

                { role: converse_role(msg.role), content: blocks }
              end
            end

            def render_invoke_messages(messages)
              return [] unless messages

              messages.filter_map do |msg|
                role = msg.role.to_s
                next if role == 'system'

                content = case role
                          when 'tool'      then invoke_tool_result_content(msg)
                          when 'assistant' then invoke_assistant_content(msg)
                          else                  invoke_user_content(msg)
                          end
                next if content.nil? || (content.is_a?(Array) && content.empty?)

                { role: role == 'tool' ? 'user' : role, content: content }
              end
            end

            def convers_content_for(msg)
              return convers_tool_result_blocks(msg) if msg.role == :tool
              return convers_assistant_blocks(msg) if msg.role == :assistant && msg.tool_calls && !msg.tool_calls.empty?

              if msg.content.is_a?(Array)
                msg.content.filter_map { |cb| extract_text_block(cb) }.compact
              else
                text = msg.content.to_s.strip
                text.empty? ? [] : [{ text: text }]
              end
            end

            def extract_text_block(block)
              return nil unless block

              type = block.respond_to?(:type) ? block.type.to_s : (block[:type] || block['type'] || 'text').to_s
              case type
              when 'text'
                text = block.respond_to?(:text) ? block.text : (block[:text] || block['text'])
                text && !text.to_s.strip.empty? ? { text: text.to_s.strip } : nil
              when 'tool_result'
                build_convers_tool_result(block)
              end
            end

            def build_convers_tool_result(block)
              tool_use_id = if block.respond_to?(:tool_use_id)
                              block.tool_use_id
                            else
                              block[:tool_use_id] || block['tool_use_id']
                            end
              content_text = if block.respond_to?(:text)
                               block.text.to_s
                             elsif block.respond_to?(:content)
                               Array(block.content).filter_map do |c|
                                 c.respond_to?(:text) ? c.text : (c['text'] || c[:text])
                               end.join
                             else
                               block.to_s
                             end
              { tool_result: { tool_use_id: tool_use_id, content: [{ text: content_text.to_s }] } }
            end

            def convers_tool_result_blocks(msg)
              return [] unless msg

              tool_call_id = if msg.respond_to?(:tool_call_id)
                               msg.tool_call_id.to_s
                             elsif msg.is_a?(Hash)
                               (msg[:tool_call_id] || msg['tool_call_id']).to_s
                             end
              result_text = if msg.respond_to?(:content)
                              msg.content.to_s
                            elsif msg.respond_to?(:tool_results)
                              msg.tool_results.to_s
                            elsif msg.is_a?(Hash)
                              (msg[:content] || msg['content']).to_s
                            end
              [{ tool_result: { tool_use_id: tool_call_id, content: [{ text: result_text.to_s }] } }]
            end

            def convers_assistant_blocks(msg)
              blocks = []
              text = msg.respond_to?(:content) ? convert_to_text(msg.content) : msg.to_s
              blocks << { text: text } if text && !text.strip.empty?

              tc_array = msg.tool_calls.is_a?(Hash) ? msg.tool_calls.values : Array(msg.tool_calls)
              tc_array&.each do |tc|
                tc_h = tc.is_a?(Hash) ? tc : tc.to_h
                blocks << {
                  tool_use: {
                    tool_use_id: (tc_h[:id] || '').to_s,
                    name: (tc_h[:name] || '').to_s,
                    input: tc_h[:arguments] || {}
                  }
                }
              end
              blocks
            end

            def invoke_user_content(msg)
              content = msg.respond_to?(:content) ? msg.content : (msg[:content] || msg['content'])
              if content.is_a?(String)
                [{ type: 'text', text: content }]
              elsif content.is_a?(Array)
                content.filter_map do |block|
                  type = content_block_type(block)
                  next { type: 'text', text: content_block_text(block) } if type == 'text'

                  block
                end
              else
                [{ type: 'text', text: content.to_s }]
              end
            end

            def content_block_type(block)
              block.respond_to?(:type) ? block.type.to_s : (block[:type] || block['type'] || 'text').to_s
            end

            def content_block_text(block)
              block.respond_to?(:text) ? block.text : (block[:text] || block['text'])
            end

            def invoke_tool_result_content(msg)
              tool_call_id = if msg.respond_to?(:tool_call_id)
                               msg.tool_call_id.to_s
                             else
                               (msg[:tool_call_id] || msg['tool_call_id']).to_s
                             end
              result_text  = if msg.respond_to?(:content)
                               msg.content.to_s
                             elsif msg.respond_to?(:tool_results)
                               msg.tool_results.to_s
                             elsif msg.is_a?(Hash)
                               (msg[:content] || msg['content']).to_s
                             end
              [{ type: 'tool_result', tool_use_id: tool_call_id, content: [{ type: 'text', text: result_text }] }]
            end

            def invoke_assistant_content(msg)
              blocks = []
              text = if msg.respond_to?(:content)
                       convert_to_text(msg.content)
                     else
                       (msg[:content] || msg['content'] || '').to_s
                     end
              blocks << { type: 'text', text: text } unless text.strip.empty?

              tc_raw = msg.respond_to?(:tool_calls) ? msg.tool_calls : msg[:tool_calls] || msg['tool_calls'] || {}
              Array(tc_raw.is_a?(Hash) ? tc_raw.values : tc_raw).each do |tc|
                tc_h = tc.is_a?(Hash) ? tc : tc.to_h
                blocks << {
                  type: 'tool_use',
                  id: (tc_h[:id] || '').to_s,
                  name: (tc_h[:name] || '').to_s,
                  input: tc_h[:arguments] || {}
                }
              end
              blocks
            end
          end
        end
      end
    end
  end
end
