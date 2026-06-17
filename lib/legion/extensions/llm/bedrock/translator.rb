# frozen_string_literal: true

require 'legion/json'
require 'legion/logging/helper'
require 'legion/extensions/llm/canonical'

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Canonical provider translator for Bedrock.
        #
        # Converts between Canonical::Request/Response/Chunk and Bedrock wire formats.
        # Supports two render targets:
        #   - :converse (default) — Bedrock Converse API
        #   - :invoke_model — Bedrock invoke_model with Anthropic Messages payload

        class Translator # rubocop:disable Metrics/ClassLength, Style/Documentation
          include Legion::Logging::Helper

          DEFAULT_MAX_TOKENS = 4096

          def initialize(region: nil)
            @region = region
          end

          def capabilities
            {
              provider: 'bedrock',
              render_targets: %i[converse invoke_model],
              thinking: :budget_tokens,
              streaming: true,
              tool_calls: true,
              cache_control: false,
              stop_reasons: {
                'end_turn' => :end_turn,
                'tool_use' => :tool_use,
                'max_tokens' => :max_tokens,
                'guardrail_intervened' => :content_filter
              }
            }
          end

          # @param canonical [Canonical::Request]
          # @param target [Symbol, nil] :converse, :invoke_model, or nil (auto)
          # @return [Hash] Bedrock wire-format payload
          def render_request(canonical, target: nil)
            target ||= target_for(canonical)
            case target
            when :converse then render_converse(canonical)
            when :invoke_model then render_invoke_model(canonical)
            else raise ArgumentError, "Unknown render target: #{target.inspect}"
            end
          end

          # @param wire [Hash] Raw wire response (String or Symbol keyed)
          # @param model [String, nil]
          # @return [Canonical::Response]
          def parse_response(wire, model: nil)
            if wire.nil? || wire.empty?
              return Canonical::Response.build(
                text: '',
                tool_calls: [],
                usage: Canonical::Usage.from_hash({}),
                stop_reason: nil,
                model: model,
                routing: {},
                metadata: {}
              )
            end

            # Canonical form passthrough (for conformance kit self-test)
            if wire.key?('text') || wire.key?(:text)
              Legion::Extensions::Llm::Canonical::Response.from_hash(wire)
            elsif wire.key?('output') || wire.key?(:output)
              parse_converse_response(wire, model)
            else
              parse_invoke_model_response(wire, model)
            end
          end

          # @param raw [Hash] Raw streaming event
          # @param model [String, nil]
          # @return [Canonical::Chunk, nil]
          def parse_chunk(raw, model: nil) # rubocop:disable Lint/UnusedMethodArgument
            return nil unless raw.is_a?(Hash) && !raw.empty?

            type = (raw['type'] || raw[:type] || '').to_s

            case type
            when 'text_delta' then parse_text_delta(raw)
            when 'thinking_delta' then parse_thinking_delta(raw)
            when 'tool_call_delta' then parse_tool_call_delta(raw)
            when 'done' then parse_done_chunk(raw)
            when 'error' then parse_error_chunk(raw)
            else parse_anthropic_event(raw)
            end
          end

          # @param canonical [Canonical::Request]
          # @return [Symbol] :converse or :invoke_model
          def target_for(canonical)
            mid = model_from_request(canonical)
            has_thinking = canonical.thinking.respond_to?(:enabled?) && canonical.thinking.enabled?
            has_tools = canonical.tools && !canonical.tools.empty?

            anthropic_model?(mid) && (has_thinking || has_tools) ? :invoke_model : :converse
          end

          private

          STOP_REASON_MAP = {
            'end_turn' => :end_turn,
            'tool_use' => :tool_use,
            'max_tokens' => :max_tokens,
            'stop_sequence' => :stop_sequence,
            'content_filter' => :content_filter,
            'guardrail_intervened' => :content_filter,
            'error' => :error
          }.freeze

          MODEL_PREFIXED_FAMILIES = %w[anthropic. meta. mistral. cohere. ai21.].freeze

          # ── render: converse ───────────────────────────────────────

          def render_converse(canonical)
            mid = model_from_request(canonical)
            payload = {
              model_id: inference_profile_id(mid),
              messages: render_converse_messages(canonical.messages),
              inference_config: build_inference_config(canonical)
            }

            payload[:system] = [{ text: canonical.system.to_s }] if canonical.system && !canonical.system.to_s.empty?

            tool_cfg = build_converse_tool_config(canonical)
            payload[:tool_config] = tool_cfg if tool_cfg

            additional = build_additional_fields(canonical)
            payload[:additional_model_request_fields] = additional if additional

            params = canonical.params
            if params
              payload[:stop_sequences] = params.stop_sequences if params.stop_sequences
              payload[:seed] = params.seed if params.seed
            end

            payload[:stream] = true if canonical.stream
            payload.compact
          end

          def inference_profile_id(model_id)
            return model_id if model_id.nil? || model_id.start_with?('us.', 'eu.', 'ap.', 'arn:')

            return model_id unless MODEL_PREFIXED_FAMILIES.any? { |p| model_id.start_with?(p) }

            region = @region || 'us-east-1'
            prefix = if region.include?('eu')
                       'eu'
                     else
                       region.include?('ap') ? 'ap' : 'us'
                     end
            "#{prefix}.#{model_id}"
          end

          def build_inference_config(canonical)
            return {} unless canonical.params

            cfg = {
              max_tokens: canonical.params.max_tokens,
              temperature: canonical.params.temperature
            }

            cfg[:top_p] = canonical.params.top_p if canonical.params.top_p
            if canonical.params.top_k && anthropic_model?(model_from_request(canonical))
              cfg[:top_k] =
                canonical.params.top_k
            end
            cfg.compact
          end

          def build_additional_fields(canonical)
            return nil unless canonical.thinking

            budget = canonical_thinking_budget(canonical)
            budget ||= DEFAULT_MAX_TOKENS / 4
            { thinking: { type: 'enabled', budget_tokens: budget } }
          end

          def canonical_thinking_budget(canonical)
            return nil unless canonical.thinking

            if canonical.thinking.respond_to?(:budget) && canonical.thinking.budget
              canonical.thinking.budget
            elsif canonical.params.respond_to?(:max_thinking_tokens) && canonical.params.max_thinking_tokens
              canonical.params.max_thinking_tokens
            end
          end

          def build_converse_tool_config(canonical)
            return nil unless canonical.tools && !canonical.tools.empty?

            tools = canonical.tools.values.map do |tool|
              {
                tool_spec: {
                  name: tool.name,
                  description: tool.description.to_s,
                  input_schema: { json: tool.parameters }
                }
              }
            end

            result = { tools: tools }
            choice = canonical.tool_choice
            result[:tool_choice] = converse_tool_choice(choice) if choice
            result.compact
          end

          def converse_tool_choice(choice)
            return { auto: {} } if choice.nil? || choice == :auto

            case choice
            when :required, 'required' then { any: {} }
            else { tool: { name: choice.to_s } }
            end
          end

          # ── render: invoke_model ───────────────────────────────────

          def render_invoke_model(canonical)
            body = {
              max_tokens: canonical.params&.max_tokens || DEFAULT_MAX_TOKENS,
              messages: render_invoke_messages(canonical.messages),
              anthropic_version: 'bedrock-2023-05-31'
            }

            sys = render_invoke_system(canonical)
            body[:system] = sys if sys

            temp = canonical.params&.temperature
            body[:temperature] = temp if temp

            tool_data = build_invoke_tools(canonical)
            body[:tools] = tool_data[:tools] if tool_data && tool_data[:tools]
            body[:tool_choice] = tool_data[:tool_choice] if tool_data && tool_data[:tool_choice]

            thinking_cfg = build_invoke_thinking(canonical)
            body[:thinking] = thinking_cfg if thinking_cfg

            body[:stream] = true if canonical.stream
            body.compact
          end

          def build_invoke_thinking(canonical)
            return nil unless canonical.thinking

            budget = canonical_thinking_budget(canonical)
            budget ||= DEFAULT_MAX_TOKENS / 4
            { type: 'enabled', budget_tokens: budget }
          end

          def render_invoke_system(canonical)
            sys = canonical.system
            return nil if sys.nil? || sys.to_s.strip.empty?

            if sys.is_a?(Array)
              sys.map do |block|
                wire = { type: 'text', text: (block[:text] || block['text'] || block.to_s).to_s }
                cc = block[:cache_control] || block['cache_control']
                wire[:cache_control] = cc if cc
                wire
              end
            else
              [{ type: 'text', text: sys.to_s }]
            end
          end

          def build_invoke_tools(canonical)
            return nil unless canonical.tools && !canonical.tools.empty?

            tools = canonical.tools.values.map do |tool|
              {
                name: tool.name,
                description: (tool.description || '').to_s,
                input_schema: tool.parameters
              }
            end

            result = { tools: tools }
            choice = canonical.tool_choice
            result[:tool_choice] = invoke_tool_choice(choice) if choice
            result
          end

          def invoke_tool_choice(choice)
            return { type: 'auto' } if choice.nil? || choice == :auto

            case choice
            when :required, 'required' then { type: 'any' }
            else { type: 'tool', name: choice.to_s }
            end
          end

          # ── message rendering ─────────────────────────────────────

          def render_converse_messages(messages)
            return [] unless messages

            messages.filter_map.with_index do |msg, _idx|
              next if msg.role == :system

              blocks = convers_content_for(msg)
              next if blocks.empty?

              {
                role: converse_role(msg.role),
                content: blocks
              }
            end
          end

          def render_invoke_messages(messages)
            return [] unless messages

            messages.filter_map do |msg|
              role = msg.role.to_s
              next if role == 'system'

              content = case role
                        when 'tool' then invoke_tool_result_content(msg)
                        when 'assistant' then invoke_assistant_content(msg)
                        else invoke_user_content(msg)
                        end

              next if content.nil? || (content.is_a?(Array) && content.empty?)

              { role: role == 'tool' ? 'user' : role, content: content }
            end
          end

          # ── convers_content building (converse API) ───────────────

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
            text = if msg.respond_to?(:content)
                     convert_to_text(msg.content)
                   else
                     msg.to_s
                   end
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

          # ── invoke model content building ──────────────────────────

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
            [{ type: 'tool_result', tool_use_id: tool_call_id, content: [{ type: 'text', text: result_text }] }]
          end

          def invoke_assistant_content(msg)
            blocks = []
            text = if msg.respond_to?(:content)
                     convert_to_text(msg.content)
                   else
                     (msg[:content] || (msg['content'] || '')).to_s
                   end
            blocks << { type: 'text', text: text } unless text.strip.empty?

            tc_raw = if msg.respond_to?(:tool_calls)
                       msg.tool_calls
                     elsif msg.is_a?(Hash)
                       msg[:tool_calls] || msg['tool_calls'] || {}
                     end
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

          # ── helpers ───────────────────────────────────────────────

          def converse_role(role)
            case role
            when :assistant then 'assistant'
            else 'user'
            end
          end

          def convert_to_text(content)
            if content.is_a?(String)
              content.strip
            elsif content.is_a?(Array)
              content.filter_map { |c| c.respond_to?(:text) ? c.text : c['text'] || c[:text] }.join
            else
              content.to_s.strip
            end
          end

          def map_stop_reason(raw)
            return nil if raw.nil? || raw.to_s.empty?

            STOP_REASON_MAP.fetch(raw.to_s, raw.to_sym)
          end

          # ── parse: converse response ──────────────────────────────

          def parse_converse_response(wire, model)
            output = read_from(wire, 'output', :output)
            message = read_from(output, 'message', :message)
            content = read_from(message, 'content', :content)
            usage_raw = read_from(wire, 'usage', :usage) || {}
            additional = read_from(wire, 'additional_model_response_fields', :additional_model_response_fields)

            text = extract_text_from(content)
            thinking_text = extract_thinking_from_content(content)
            thinking_text ||= extract_thinking_from_fields(additional)
            thinking_obj = if thinking_text && !thinking_text.to_s.empty?
                             Canonical::Thinking.new(content: thinking_text.to_s, signature: nil)
                           end
            tool_calls_list = extract_tool_calls_from(content)
            usage = parse_usage(usage_raw)
            sr = extract_stop_reason_from(message)

            Canonical::Response.build(
              text: text,
              thinking: thinking_obj,
              tool_calls: tool_calls_list,
              usage: usage,
              stop_reason: map_stop_reason(sr),
              model: model,
              routing: {},
              metadata: {}
            )
          end

          def extract_text_from(content_blocks)
            Array(content_blocks).filter_map do |block|
              read_from(block, 'text', :text).to_s
            end.join
          end

          def extract_thinking_from_content(content_blocks)
            Array(content_blocks).each do |block|
              reasoning = read_from(block, 'reasoning', :reasoning)
              next if reasoning.nil?

              text = if reasoning.is_a?(Hash)
                       reasoning[:text] || reasoning['text']
                     elsif reasoning.respond_to?(:text)
                       begin; reasoning.text; rescue StandardError; nil; end
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
            calls = Array(content_blocks).filter_map do |block|
              read_from(block, 'tool_use', :tool_use)
            end
            return [] if calls.empty?

            calls.map do |call|
              tc_id = safe_read(call, :tool_use_id, 'tool_use_id', '')
              name = safe_read(call, :name, 'name', '')
              input = safe_read(call, :input, 'input', {})

              if input.is_a?(String)
                begin
                  input = Legion::JSON.load(input)
                rescue Legion::JSON::ParseError
                  input = {}
                end
              end
              input = {} unless input.is_a?(Hash)

              Canonical::ToolCall.build(
                id: tc_id.to_s,
                name: name.to_s,
                arguments: input,
                source: :client,
                status: :pending
              )
            end
          end

          def extract_stop_reason_from(message)
            return nil unless message

            read_from(message, 'stop_reason', :stop_reason)
          rescue StandardError
            nil
          end

          # ── parse: invoke_model response ──────────────────────────

          def parse_invoke_model_response(wire, model)
            content = wire['content'] || wire[:content] || []
            usage_raw = wire['usage'] || wire[:usage] || {}
            stop_raw = wire['stop_reason'] || wire[:stop_reason]

            text = Array(content).filter_map { |b| b['type'] == 'text' ? b['text'] : nil }.join

            thinking_parts = Array(content).select { |b| b['type'] == 'thinking' }
            thinking_obj = if thinking_parts.any?
                             tp = thinking_parts.last
                             Canonical::Thinking.new(content: tp['thinking'], signature: tp['signature'])
                           end

            tool_calls_list = Array(content).select { |b| b['type'] == 'tool_use' }.map do |b|
              args = b['input'] || {}
              if args.is_a?(String)
                begin
                  args = Legion::JSON.load(args)
                rescue Legion::JSON::ParseError
                  args = {}
                end
              end

              Canonical::ToolCall.build(
                id: b['id'],
                name: b['name'],
                arguments: args.is_a?(Hash) ? args : {},
                source: :client,
                status: :pending
              )
            end

            usage = parse_usage(usage_raw)

            Canonical::Response.build(
              text: text,
              thinking: thinking_obj,
              tool_calls: tool_calls_list,
              usage: usage,
              stop_reason: map_stop_reason(stop_raw),
              model: model,
              routing: {},
              metadata: {}
            )
          end

          # ── parse: streaming chunks ──────────────────────────────

          def parse_text_delta(raw)
            delta = raw['delta'] || raw[:delta] || {}
            text = delta.is_a?(Hash) ? (delta['text'] || delta[:text] || '') : delta.to_s
            return nil if text.to_s.empty?

            Canonical::Chunk.text_delta(
              delta: text.to_s,
              request_id: raw['request_id'] || raw[:request_id] || ''
            )
          end

          def parse_thinking_delta(raw)
            delta = raw['delta'] || raw[:delta] || {}
            text = if delta.is_a?(Hash)
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

          def parse_tool_call_delta(raw)
            tc_hash = raw['tool_call'] || raw[:tool_call]
            return nil unless tc_hash

            tc = Canonical::ToolCall.build(
              id: tc_hash[:id] || tc_hash['id'] || '',
              name: tc_hash[:name] || tc_hash['name'] || '',
              arguments: tc_hash[:arguments] || tc_hash['arguments'] || {},
              source: tc_hash[:source] || tc_hash['source'] || :client,
              status: tc_hash[:status] || tc_hash['status'] || :pending
            )

            Canonical::Chunk.tool_call_delta(
              tool_call: tc,
              request_id: raw['request_id'] || raw[:request_id] || ''
            )
          end

          def parse_done_chunk(raw)
            usage_raw = raw['usage'] || raw[:usage]
            usage = usage_raw ? parse_usage(usage_raw) : nil
            stop = map_stop_reason(raw['stop_reason'] || raw[:stop_reason])

            Canonical::Chunk.done(
              request_id: raw['request_id'] || raw[:request_id] || '',
              usage: usage,
              stop_reason: stop
            )
          end

          def parse_error_chunk(raw)
            metadata = raw['metadata'] || raw[:metadata] || {}
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
              delta = nested_read(raw, 'delta', 'text', :text) ||
                      nested_read(raw, 'delta', 'text', :delta, :text)
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

          # ── parse: usage ──────────────────────────────────────────

          def parse_usage(usage_raw)
            return Canonical::Usage.from_hash({}) unless usage_raw

            h = {}
            if usage_raw.is_a?(Hash)
              h[:input_tokens] = usage_raw[:input_tokens] || usage_raw['input_tokens']
              h[:output_tokens] = usage_raw[:output_tokens] || usage_raw['output_tokens']
              h[:cache_read_tokens] = usage_raw[:cache_read_input_tokens] || usage_raw['cache_read_input_tokens']
              h[:cache_write_tokens] =
                usage_raw[:cache_creation_input_tokens] || usage_raw['cache_creation_input_tokens']
              h[:thinking_tokens] = usage_raw[:thinking_tokens] || usage_raw['thinking_tokens']
            else
              h[:input_tokens] = safe_key_read(usage_raw, :input_tokens)
              h[:output_tokens] = safe_key_read(usage_raw, :output_tokens)
              h[:cache_read_tokens] = safe_key_read(usage_raw, :cache_read_input_tokens)
              h[:cache_write_tokens] = safe_key_read(usage_raw, :cache_creation_input_tokens)
              h[:thinking_tokens] = safe_key_read(usage_raw, :thinking_tokens)
            end

            Canonical::Usage.from_hash(h)
          end

          # ── read helpers ──────────────────────────────────────────

          def read_from(obj, *keys)
            return nil unless obj

            keys.each do |key|
              val = nil
              if obj.is_a?(Hash)
                val = obj[key]
              elsif obj.respond_to?(key)
                begin
                  val = obj.public_send(key)
                rescue StandardError
                  val = nil
                end
              elsif obj.respond_to?(:to_h) && obj.to_h.key?(key)
                val = obj.to_h[key]
              end
              return val unless val.nil?
            end
            nil
          end

          def safe_read(obj, sym_key, str_key, default = nil)
            return obj[sym_key] || obj[str_key] || default if obj.is_a?(Hash)

            safe_key_read(obj, sym_key) || default
          end

          def safe_key_read(obj, key)
            return nil unless obj

            if obj.is_a?(Hash)
              obj[key] || obj[key.to_s]
            elsif obj.respond_to?(:key?) && obj.key?(key)
              begin
                obj[key]
              rescue ::NameError, ::NoMethodError => _e
                nil
              end
            elsif obj.respond_to?(key)
              begin
                obj.public_send(key)
              rescue ::NameError, ::NoMethodError => _e
                nil
              end
            end
          end

          def nested_read(obj, *keys)
            current = obj
            keys.each do |key|
              return nil unless current.is_a?(Hash)

              current = current[key]
            end
            current
          end

          # ── canonical params ──────────────────────────────────────

          def model_from_request(canonical)
            canonical.routing[:model] || canonical.metadata[:model] ||
              canonical.messages&.first&.model
          end

          # ── model detection ───────────────────────────────────────

          def anthropic_model?(model_id)
            return false unless model_id

            mid = model_id.to_s
            mid.start_with?('anthropic.', 'us.anthropic.', 'eu.anthropic.', 'ap.anthropic.')
          end
        end
      end
    end
  end
end
