# frozen_string_literal: true

require 'legion/json'
require 'legion/logging/helper'
require 'legion/extensions/llm/canonical'
require_relative 'thinking_modes'
require_relative 'translator/read_helpers'
require_relative 'translator/request_rendering'
require_relative 'translator/message_rendering'
require_relative 'translator/response_parsing'
require_relative 'translator/chunk_parsing'

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

          DEFAULT_MAX_TOKENS = 4096

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
          def target_for(canonical)
            mid       = model_from_request(canonical)
            has_think = canonical.thinking.respond_to?(:enabled?) && canonical.thinking.enabled?
            has_tools = canonical.tools && !canonical.tools.empty?
            anthropic_model?(mid) && (has_think || has_tools) ? :invoke_model : :converse
          end
        end
      end
    end
  end
end
