# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Translator
          # Message rendering helpers for both Converse API and invoke_model wire formats.
          #
          # B22: canonical-in, wire-out. The only input shape is
          # Canonical::Message (the request normalizer guarantees it) — the
          # recovery-§4 dual-shape reads (respond_to?/Hash), the msg.to_s
          # fallbacks, and the fabricated {} tool_use inputs are deleted: the
          # canonical type carries the fact, and a missing tool-call argument
          # is the type's own documented no-arguments value, not a renderer
          # fabrication.
          module MessageRendering
            private

            def render_converse_messages(messages)
              return [] unless messages

              messages.filter_map do |msg|
                blocks = convers_content_for(msg)
                next if blocks.empty?

                { role: converse_role(msg.role), content: blocks }
              end
            end

            def render_invoke_messages(messages)
              return [] unless messages

              messages.filter_map do |msg|
                role = msg.role.to_s
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
              return convers_assistant_blocks(msg) if msg.role == :assistant && !msg.tool_calls.to_a.empty?

              text = convert_to_text(msg.content).strip
              text.empty? ? [] : [{ text: text }]
            end

            def convers_tool_result_blocks(msg)
              return [] if msg.tool_call_id.nil?

              [{ tool_result: { tool_use_id: msg.tool_call_id, content: [{ text: msg.text.to_s }] } }]
            end

            def convers_assistant_blocks(msg)
              blocks = []
              text = convert_to_text(msg.content)
              blocks << { text: text } if text && !text.strip.empty?

              Array(msg.tool_calls).each do |call|
                blocks << {
                  tool_use: {
                    tool_use_id: call.id,
                    name: call.name,
                    input: call.arguments
                  }
                }
              end
              blocks
            end

            def invoke_user_content(msg)
              case msg.content
              when ::String
                [{ type: 'text', text: msg.content }]
              when ::Array
                msg.content.filter_map { |block| invoke_user_block(block) }
              when Canonical::ContentBlock
                block = invoke_user_block(msg.content)
                block ? [block] : []
              else
                []
              end
            end

            # One Anthropic-wire user-content block from a canonical block:
            # text and image render; other block types have no Anthropic
            # user-content spelling and do not render.
            def invoke_user_block(block)
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

            def invoke_tool_result_content(msg)
              return [] if msg.tool_call_id.nil?

              [{ type: 'tool_result', tool_use_id: msg.tool_call_id,
                 content: [{ type: 'text', text: msg.text.to_s }] }]
            end

            def invoke_assistant_content(msg)
              blocks = []
              text = convert_to_text(msg.content)
              blocks << { type: 'text', text: text } unless text.strip.empty?

              Array(msg.tool_calls).each do |call|
                blocks << {
                  type: 'tool_use',
                  id: call.id,
                  name: call.name,
                  input: call.arguments
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
