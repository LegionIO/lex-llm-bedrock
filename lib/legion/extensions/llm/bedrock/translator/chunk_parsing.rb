# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Translator
          # Streaming chunk parsing helpers (text_delta, thinking_delta, tool_call_delta, etc.)
          module ChunkParsing
            private

            def parse_text_delta(raw)
              delta = raw['delta'] || raw[:delta] || {}
              text  = delta.is_a?(Hash) ? (delta['text'] || delta[:text] || '') : delta.to_s
              return nil if text.to_s.empty?

              Canonical::Chunk.text_delta(
                delta: text.to_s,
                request_id: raw['request_id'] || raw[:request_id] || ''
              )
            end

            def parse_thinking_delta(raw)
              delta = raw['delta'] || raw[:delta] || {}
              text  = if delta.is_a?(Hash)
                        delta['thinking'] || delta[:thinking] || delta['text'] || delta[:text] || ''
                      else
                        (raw['delta'] || '').to_s
                      end
              return nil if text.to_s.empty?

              Canonical::Chunk.thinking_delta(
                delta: text.to_s,
                request_id: raw['request_id'] || raw[:request_id] || '',
                signature: raw['signature'] || raw[:signature]
              )
            end

            # B6: the chunk's tool_call member is the delta FRAGMENT (the
            # Chunk contract: Hash with the current state, arguments a String
            # fragment until assembled) — it is passed through, never rebuilt
            # into a ToolCall with a fabricated {} when arguments are still
            # pending.
            def parse_tool_call_delta(raw)
              tc_hash = raw['tool_call'] || raw[:tool_call]
              return nil unless tc_hash.is_a?(Hash) && !tc_hash.empty?

              Canonical::Chunk.tool_call_delta(
                tool_call: tc_hash,
                request_id: raw['request_id'] || raw[:request_id] || ''
              )
            end

            def parse_done_chunk(raw)
              usage_raw = raw['usage'] || raw[:usage]
              usage = usage_raw ? parse_usage(usage_raw) : nil
              stop  = map_stop_reason(raw['stop_reason'] || raw[:stop_reason])
              Canonical::Chunk.done(
                request_id: raw['request_id'] || raw[:request_id] || '',
                usage: usage,
                stop_reason: stop
              )
            end

            def parse_error_chunk(raw)
              metadata   = raw['metadata'] || raw[:metadata] || {}
              error_data = metadata[:error] || metadata['error'] || { message: 'Stream error' }
              Canonical::Chunk.error_chunk(
                error: error_data.is_a?(Hash) ? error_data : { message: error_data.to_s },
                request_id: raw['request_id'] || raw[:request_id] || '',
                metadata: metadata
              )
            end

            def parse_anthropic_event(raw)
              event_type = raw['type'] || raw[:type]
              return nil if event_type.nil?

              request_id = raw['request_id'] || raw[:request_id] || ''
              case event_type
              when 'text_delta'
                delta = nested_read(raw, 'delta', 'text', :text) || nested_read(raw, 'delta', 'text', :delta, :text)
                return nil unless delta && !delta.to_s.empty?

                Canonical::Chunk.text_delta(delta: delta.to_s, request_id: request_id)
              when 'thinking_delta'
                delta = nested_read(raw, 'delta', 'thinking', :thinking) ||
                        nested_read(raw, 'delta', 'thinking', :delta, :thinking)
                sig = raw['signature'] || raw[:signature]
                return nil unless delta && !delta.to_s.empty?

                Canonical::Chunk.thinking_delta(delta: delta.to_s, request_id: request_id, signature: sig)
              when 'input_json_delta'
                tc_hash = raw['tool_call'] || raw[:tool_call]
                return nil unless tc_hash

                tc = Canonical::ToolCall.build(
                  id: tc_hash[:id] || tc_hash['id'] || '',
                  name: tc_hash[:name] || tc_hash['name'] || '',
                  arguments: tc_hash[:arguments] || tc_hash['arguments'] || {},
                  status: :pending
                )
                Canonical::Chunk.tool_call_delta(tool_call: tc, request_id: request_id)
              when 'message_delta'
                stop = nested_read(raw, 'delta', 'stop_reason', :stop_reason) || ''
                Canonical::Chunk.done(request_id: request_id, stop_reason: map_stop_reason(stop))
              end
            end
          end
        end
      end
    end
  end
end
