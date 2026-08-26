# frozen_string_literal: true

require 'legion/json'
require 'legion/logging/helper'
require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/bedrock/thinking_modes'
require 'legion/extensions/llm/bedrock/render_defaults'
require 'legion/extensions/llm/bedrock/translator/read_helpers'
require 'legion/extensions/llm/bedrock/translator/request_rendering'
require 'legion/extensions/llm/bedrock/translator/message_rendering'
require 'legion/extensions/llm/bedrock/translator/response_parsing'
require 'legion/extensions/llm/bedrock/translator/chunk_parsing'

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
        class Translator
          include Legion::Logging::Helper
          include ReadHelpers
          include RequestRendering
          include MessageRendering
          include ResponseParsing
          include ChunkParsing

          # Wire spelling table (13 §3 edge): the Converse API spells the
          # content-filter stop reason 'content_filtered'; Anthropic event
          # streams spell it 'content_filter'. Both map to the canonical
          # :content_filter (Canonical::Response::STOP_REASONS).
          STOP_REASON_MAP = {
            'end_turn' => :end_turn,
            'tool_use' => :tool_use,
            'max_tokens' => :max_tokens,
            'stop_sequence' => :stop_sequence,
            'content_filter' => :content_filter,
            'content_filtered' => :content_filter,
            'guardrail_intervened' => :content_filter,
            'error' => :error
          }.freeze

          MODEL_PREFIXED_FAMILIES = %w[anthropic. meta. mistral. cohere. ai21.].freeze

          def initialize(region: nil, geo_prefix: nil)
            @region     = region
            @geo_prefix = geo_prefix
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
            reject_system_messages!(canonical)
            target ||= target_for(canonical)
            case target
            when :converse     then render_converse(canonical)
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
                text: '', tool_calls: [], usage: Canonical::Usage.from_hash({}),
                stop_reason: nil, model: model, routing: {}, metadata: {}
              )
            end

            if wire.key?('text') || wire.key?(:text)
              Legion::Extensions::Llm::Canonical::Response.from_hash(wire)
            elsif wire.key?('output') || wire.key?(:output)
              parse_converse_response(wire, model)
            else
              parse_invoke_model_response(wire, model)
            end
          end

          # @param raw [Hash] Raw streaming event
          # @return [Canonical::Chunk, nil]
          def parse_chunk(raw, _model: nil)
            return nil unless raw.is_a?(Hash) && !raw.empty?

            type = (raw['type'] || raw[:type] || '').to_s
            case type
            when 'text_delta'      then parse_text_delta(raw)
            when 'thinking_delta'  then parse_thinking_delta(raw)
            when 'tool_call_delta' then parse_tool_call_delta(raw)
            when 'done'            then parse_done_chunk(raw)
            when 'error'           then parse_error_chunk(raw)
            else parse_anthropic_event(raw)
            end
          end

          # @param canonical [Canonical::Request]
          # @return [Symbol] :converse or :invoke_model
          # B1: the dialect predicate has one owner — ThinkingModes, shared
          # with the Provider dispatch path.
          def target_for(canonical)
            mid = model_from_request(canonical)
            if ThinkingModes.invoke_model_target?(model_id: mid, thinking: canonical.thinking, tools: canonical.tools)
              :invoke_model
            else
              :converse
            end
          end

          private

          # B5: the system MEMBER is the single system source. System-role
          # messages are bridge residue that request construction folds into
          # the member (the vLLM bridge law) — rendering from them, or
          # silently dropping them, is the two-source defect (poison fails,
          # it does not render).
          def reject_system_messages!(canonical)
            canonical.messages&.each do |message|
              if message.role == :system
                raise ArgumentError,
                      'bedrock.render_request: system-role messages must be folded into the system member'
              end
            end
          end
        end
      end
    end
  end
end
