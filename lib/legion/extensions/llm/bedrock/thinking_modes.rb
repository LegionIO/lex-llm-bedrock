# frozen_string_literal: true

require 'legion/extensions/llm/canonical'

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Single source of truth for how each Bedrock model expresses extended
        # thinking on the wire. Shared by both the Provider (invoke_model /
        # converse paths) and the Translator (canonical render path) so the two
        # never diverge.
        #
        # Bedrock supports exactly one thinking wire shape for Anthropic Claude:
        #   { type: 'enabled', budget_tokens: N }   (native Anthropic Messages API)
        #
        # There is NO Bedrock Claude model that accepts { type: 'adaptive' } —
        # sending adaptive raises `ValidationException: adaptive thinking is not
        # supported on this model` (observed live on opus-4-5) and surfaces as an
        # HTTP 500. So a model either supports budgeted thinking (emit `enabled`)
        # or it does not (OMIT the thinking field entirely — never `adaptive`).
        #
        # Budgeted extended thinking arrived with Claude 3.7 Sonnet and is
        # supported across the entire Claude 4 family (sonnet-4, opus-4.x,
        # haiku-4.5). The match is a substring so it tolerates the many Bedrock
        # model-id decorations (geo prefixes `us.`/`eu.`/`ap.`, `anthropic.`
        # provider prefix, `-vN:0` version suffixes, `:200k` context suffixes).
        module ThinkingModes
          module_function

          # Model-id fragments for Claude families that support explicit budgeted
          # extended thinking via { type: 'enabled', budget_tokens: N }.
          BUDGETED_THINKING_FRAGMENTS = %w[
            claude-3-7-sonnet
            claude-sonnet-4
            claude-opus-4
            claude-haiku-4
          ].freeze

          # @return [Boolean] true when the model supports { type: 'enabled', budget_tokens: N }
          def budgeted_thinking?(model_id)
            return false if model_id.nil? || model_id.to_s.strip.empty?

            mid = model_id.to_s
            # Substring scan (String#include?), NOT array intersection: intersect?
            # raises TypeError on a String argument.
            BUDGETED_THINKING_FRAGMENTS.any? { |fragment| mid.include?(fragment) }
          end

          # @return [Boolean] true when the model is KNOWN not to support thinking.
          # Distinct from `!budgeted_thinking?`: a nil/blank/unknown model id is
          # NOT known-unsupported — we then honor an explicit thinking request and
          # emit the (safe) `enabled` shape rather than dropping it. The router's
          # capability filter (fed by the shared catalog) is the real guard that
          # keeps thinking requests off non-thinking models; this method only
          # strips thinking for a positively-identified non-thinking Claude model
          # so we never emit an unsupported shape and 500.
          def known_non_thinking?(model_id)
            return false if model_id.nil? || model_id.to_s.strip.empty?

            mid = model_id.to_s
            return false unless mid.include?('anthropic') || mid.include?('claude')

            !budgeted_thinking?(model_id)
          end

          # The single anthropic-model-id predicate (was duplicated in the
          # provider invoke helpers and the translator read helpers).
          def anthropic_model?(model_id)
            return false unless model_id

            model_id.to_s.start_with?('anthropic.', 'us.anthropic.', 'eu.anthropic.', 'ap.anthropic.')
          end

          # B1: the single Converse-vs-invoke_model selection predicate — one
          # owner, one predicate, shared by the Provider dispatch path and the
          # Translator. A present-but-disabled Thinking::Config (no effort, no
          # budget) does NOT force the invoke dialect: enabled? is the law,
          # the provider path's old object-truthiness fork is deleted.
          def invoke_model_target?(model_id:, thinking:, tools:)
            anthropic_model?(model_id) && (thinking_enabled?(thinking) || (tools && !tools.empty?))
          end

          # B3: the dispatch boundary carries Canonical::Thinking::Config only
          # (the fleet wire hash is rehydrated at the W4 boundary, core side);
          # a non-Config value here is a boundary violation.
          def thinking_enabled?(thinking)
            thinking.is_a?(Legion::Extensions::Llm::Canonical::Thinking::Config) && thinking.enabled?
          end

          # B2: the single thinking wire-shape builder — { type: 'enabled',
          # budget_tokens: N } or nil. Consumed by both dialects and both
          # render stacks. The budget resolves through the shared
          # effort<->budget SSOT (resolved_budget), so an effort-only config
          # gets its SSOT-mapped budget instead of a fabricated 1024, and a
          # budget-less { type: 'enabled' } (the Bedrock ValidationException
          # shape) is unreachable: an enabled config always resolves a budget.
          def thinking_wire(thinking:, model_id:, params: nil)
            return nil unless thinking_enabled?(thinking)
            return nil if known_non_thinking?(model_id)

            budget = thinking.resolved_budget || params&.max_thinking_tokens
            if budget.nil?
              raise ArgumentError,
                    "bedrock.thinking_wire: enabled thinking has no resolvable budget_tokens for #{model_id}"
            end

            { type: 'enabled', budget_tokens: budget }
          end
        end
      end
    end
  end
end
