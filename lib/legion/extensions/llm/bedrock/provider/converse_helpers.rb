# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Provider
          # Converse API request formatting, response parsing, and stream handling.
          #
          # 0.8.0 renderer/parser law (08 R1-R4): render FROM Canonical::Message /
          # Canonical::ContentBlock values; parse TO Canonical::Response /
          # Canonical::Chunk. Wire-dialect tolerance (provider-spelled keys,
          # MIME media types) lives in these renderers only.
          module ConverseHelpers
            private

            # 08 R1/F4: the request renderer receives canonical values —
            # sampling scalars are read from the Canonical::Params members
            # (params.temperature / params.max_tokens), never from a raw hash.
            # B5: system arrives as the folded member value (the dispatch
            # edge folded system-role messages); messages are system-free.
            # B18: max_tokens has one owner (RenderDefaults).
            def converse_request(messages, model:, params:, tools:, tool_prefs:, system: nil, thinking: nil)
              inference_config = {
                temperature: params&.temperature,
                max_tokens: RenderDefaults.max_tokens(params, target: :converse)
              }.compact
              additional = bedrock_additional_fields(thinking, model: model_id(model)) || {}
              additional[:response_format] = params&.response_format if params&.response_format

              {
                model_id: self.class.inference_profile_id(model_id(model), geo_prefix: geo_prefix),
                messages: format_messages(messages),
                system: system_blocks(system),
                inference_config: inference_config,
                tool_config: format_tool_config(tools, tool_prefs),
                additional_model_request_fields: additional.empty? ? nil : additional
              }.compact
            end

            # B2: one shared thinking wire builder (ThinkingModes) — the
            # Hash-read/fabricated-1024 path is deleted.
            def bedrock_additional_fields(thinking, model:)
              wire = ThinkingModes.thinking_wire(thinking:, model_id: model)
              wire ? { thinking: wire } : nil
            end

            # B21: the dead cache-control stub is deleted — Converse has no
            # cache_control, and a policy that computes eligibility it never
            # applies invites a half-applied "fix".
            def format_messages(messages)
              formatted = messages.filter_map do |message|
                blocks = build_content_blocks(message)
                next if blocks.empty?

                { role: bedrock_role(message.role), content: blocks }
              end
              consolidate_adjacent_roles(formatted)
            end

            def tool_result_blocks(message)
              return [] if message.tool_call_id.nil?

              [{
                tool_result: {
                  tool_use_id: message.tool_call_id,
                  content: [{ text: message.text.to_s }]
                }
              }]
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

              return assistant_tool_use_blocks(message) if message.role == :assistant &&
                                                           message.tool_calls && !message.tool_calls.empty?

              content_blocks(message.content)
            end

            def assistant_tool_use_blocks(message)
              blocks = []
              text = message.text.to_s
              blocks << { text: text } if text && !text.strip.empty?

              Array(message.tool_calls).each do |call|
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
              case content
              when ::String
                return [] if content.strip.empty?

                [{ text: content }]
              when Canonical::ContentBlock
                wire = content_block_wire(content)
                wire ? [wire] : []
              when ::Array
                content.filter_map { |block| content_block_wire(block) }
              else
                text = content.to_s
                return [] if text.strip.empty?

                [{ text: text }]
              end
            end

            # One Converse user-content block from a canonical block: text and
            # image render to the wire; other block types have no Bedrock
            # user-content spelling and do not render.
            def content_block_wire(block)
              return nil unless block.is_a?(Canonical::ContentBlock)

              if block.text?
                text = block.text.to_s
                return nil if text.strip.empty?

                { text: text }
              elsif block.type == :image
                format_image_block(block)
              end
            end

            def format_image_block(block)
              {
                image: {
                  format: image_format(block.media_type),
                  source: { bytes: block.data }
                }
              }
            end

            def image_format(fmt)
              mime = fmt.to_s.downcase.delete_prefix('image/')
              case mime
              when 'jpeg', 'jpg' then 'jpeg'
              when 'png' then 'png'
              when 'gif' then 'gif'
              when 'webp' then 'webp'
              end || 'jpeg'
            end

            def format_tool_config(tools, tool_prefs)
              # H3 contract: tools is Hash<name, Canonical::ToolDefinition>
              # or nil — nil renders no tool_config.
              return nil if tools.nil? || tools.empty?

              log.debug do
                "bedrock.provider.tools: formatting tools=#{tools.keys.map(&:to_s).sort.join(',')} " \
                  "tool_choice=#{tool_choice_label(tool_prefs)}"
              end
              {
                tools: tools.values.map { |tool| tool_definition(tool) },
                tool_choice: tool_choice(tool_prefs)
              }.compact
            end

            # B3: canonical-in — the dispatch funnel (enforce_canonical_tools!)
            # guarantees Canonical::ToolDefinition values; the respond_to?
            # dual reads are deleted. parameters is normalized at
            # ToolDefinition construction.
            def tool_definition(tool)
              {
                tool_spec: {
                  name: tool.name,
                  description: tool.description,
                  input_schema: { json: tool.parameters }
                }
              }
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

            # 08 R2: the single sync parse boundary — the gem's canonical
            # translator (ResponseParsing) turns the wire hash into
            # Canonical::Response.
            def parse_converse_response(response, fallback_model)
              translator.parse_response(normalize_response(response), model: fallback_model)
            end

            def cache_read_tokens(usage)
              return nil if usage.nil?

              value(usage, :cache_read_input_tokens) || value(usage, 'cache_read_input_tokens')
            end

            def cache_write_tokens(usage)
              return nil if usage.nil?

              value(usage, :cache_creation_input_tokens) || value(usage, 'cache_creation_input_tokens')
            end

            # Canonical usage from a wire usage hash/struct (provider spellings
            # translated at this edge, 13 §3).
            def usage_from(usage)
              Canonical::Usage.build(
                input_tokens: value(usage, :input_tokens),
                output_tokens: value(usage, :output_tokens),
                cache_read_tokens: cache_read_tokens(usage),
                cache_write_tokens: cache_write_tokens(usage)
              )
            end

            # One stop-reason edge: the gem's Translator map is the single
            # wire→canonical spelling table (D04). Unknown spellings pass
            # through as symbols and fail loud in Canonical::Response.
            def map_stop_reason(raw)
              return nil if raw.nil? || raw.to_s.empty?

              Legion::Extensions::Llm::Bedrock::Translator::STOP_REASON_MAP.fetch(raw.to_s, raw.to_sym)
            end

            def stream_converse(request, fallback_model, request_id: nil, &)
              state = { accumulated: +'', thinking: +'', final_usage: nil, stop_reason: nil,
                        tool_use_blocks: [], current_tool_use: nil, in_thinking: false,
                        stream_error: nil }

              log.debug do
                "bedrock.provider.stream_converse: starting model=#{fallback_model} " \
                  "tools=#{state[:tool_use_blocks].size}"
              end

              runtime_client.converse_stream(**request) do |stream|
                wire_stream_handlers(stream, state, request_id:, &)
              end

              # B7: an explicit provider error event is a dispatch failure —
              # raised before any done chunk (a truncated stream is never a
              # completed response). B6: the strict stream-end tool parse
              # happens before the done chunk for the same reason.
              raise_stream_error!(state, dialect: 'converse')
              tool_calls = build_stream_tool_calls(state[:tool_use_blocks])

              log.debug do
                "bedrock.provider.stream_converse: completed model=#{fallback_model} " \
                  "accumulated_length=#{state[:accumulated].length} thinking_length=#{state[:thinking].length} " \
                  "tool_use_blocks=#{state[:tool_use_blocks].size} stop_reason=#{state[:stop_reason]}"
              end

              yield done_chunk(state, request_id:) if block_given?
              build_stream_response(state, fallback_model, tool_calls:)
            end

            def done_chunk(state, request_id:)
              Canonical::Chunk.done(
                request_id:,
                usage: usage_from(state[:final_usage]),
                stop_reason: map_stop_reason(state[:stop_reason])
              )
            end

            # 08 R2: the stream's accumulated state builds a Canonical::Response.
            # B6/B7: tool_calls are parsed strictly BEFORE the done chunk
            # (stream_converse passes them in) — a parse failure raises before
            # the stream is ever presented as complete.
            def build_stream_response(state, fallback_model, tool_calls:)
              Canonical::Response.build(
                text: state[:accumulated],
                thinking: state[:thinking].empty? ? nil : Canonical::Thinking.build(content: state[:thinking]),
                tool_calls:,
                usage: usage_from(state[:final_usage]),
                stop_reason: map_stop_reason(state[:stop_reason]),
                model: fallback_model
              )
            end

            def wire_stream_handlers(stream, state, request_id:, &)
              wire_block_start(stream, state)
              wire_block_delta(stream, state, request_id:, &)
              wire_block_stop(stream, state)
              wire_message_stop(stream, state)
              stream.on_metadata_event { |event| state[:final_usage] = value(event, :usage) }
              # B7: the converse path had no error-event handlers at all — a
              # provider error event was invisible and the truncated stream
              # completed as success. Record it; raise before any done chunk.
              stream.on_error_event { |event| record_stream_error(state, event: event, type: 'error') }
            end

            # B7: one shared stream-error recorder for both dialects. The
            # FIRST explicit error event wins; the provider's message is kept
            # for the raised exception (local), the reason that crosses the
            # dispatch boundary is the exception class name.
            def record_stream_error(state, event:, type:)
              return unless state[:stream_error].nil?

              err = value(event, :error)
              message = value(err, :message) || event.class.name
              state[:stream_error] = { type:, message: message.to_s }
              log.warn do
                "bedrock.provider.stream: error event type=#{type} message=#{sanitize_log(message.to_s[0, 200])}"
              end
            end

            def raise_stream_error!(state, dialect:)
              return if state[:stream_error].nil?

              raise Bedrock::StreamError,
                    "bedrock #{dialect} stream failed: #{state[:stream_error][:type]}: " \
                    "#{state[:stream_error][:message]}"
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

            def wire_block_delta(stream, state, request_id:)
              stream.on_content_block_delta_event do |event|
                delta = value(event, :delta)
                text = value(delta, :text) ||
                       value(value(delta, :reasoning), :text) ||
                       value(value(delta, :thinking), :text)
                if text
                  if state[:in_thinking]
                    state[:thinking] << text
                    # B12: the converse path now streams thinking deltas like
                    # the invoke path — the dialect asymmetry (thinking only
                    # in the final response) is deleted.
                    yield Canonical::Chunk.thinking_delta(delta: text, request_id:) if block_given? && !text.empty?
                  else
                    state[:accumulated] << text
                    yield Canonical::Chunk.text_delta(delta: text, request_id:) if block_given?
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

            # Streamed tool-input JSON fragments assemble before parsing
            # (10 U2): the ONE shared strict parser (B6) — invalid JSON
            # raises, never a fabricated {}.
            def build_stream_tool_calls(tool_use_blocks)
              return [] if tool_use_blocks.empty?

              tool_use_blocks.map do |block|
                input = Legion::Extensions::Llm::Responses::ToolArguments.parse!(block[:input_json])
                name = block[:name]
                id = block[:tool_use_id] || name
                Canonical::ToolCall.build(id: id, name: name, arguments: input)
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

            # Plain text from canonical content (String | ContentBlock |
            # Array<ContentBlock>) — one text extraction for both render paths.
            def canonical_content_text(content, joiner: '')
              case content
              when ::String then content
              when Canonical::ContentBlock then content.text.to_s
              when ::Array
                content.filter_map { |b| b.is_a?(Canonical::ContentBlock) ? b.text.to_s : nil }.join(joiner)
              else
                content.to_s
              end
            end
          end
        end
      end
    end
  end
end
