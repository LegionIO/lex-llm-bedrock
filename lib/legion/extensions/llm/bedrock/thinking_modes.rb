# frozen_string_literal: true

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

            !budgeted_thinking?(model_id)
          end
        end
      end
    end
  end
end
