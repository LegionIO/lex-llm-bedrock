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
        # Bedrock supports TWO thinking wire shapes for Anthropic Claude:
        #
        # 1. BUDGETED (Claude 3.7, sonnet-4 base, opus-4 base, opus-4-5, haiku-4):
        #    { type: 'enabled', budget_tokens: N }
        #
        # 2. ADAPTIVE (Claude opus-4-6/4-7/4-8/5, sonnet-4-6/5):
        #    { type: 'adaptive' } + output_config: { effort: <low|medium|high|xhigh|max> }
        #    Gated by beta header 'effort-2025-11-24' in the anthropic_beta list.
        #    Adaptive-only models REJECT { type: 'enabled', budget_tokens: N } with
        #    `ValidationException: "thinking.type.enabled" is not supported for
        #    this model. Use "thinking.type.adaptive" and "output_config.effort"`.
        #    The effort value is passed through directly from the canonical
        #    Thinking::Config#resolved_effort (the full ladder matches 1:1).
        #    'none' or nil effort → omit output_config (API defaults to high).
        #
        # Opus 4.6 and Sonnet 4.6 support BOTH shapes. Preserve an explicit
        # budget on those models; effort-only requests use adaptive thinking.
        # Converting a supplied budget into adaptive effort changes the request
        # from manual thinking to a mode that may skip thinking altogether.
        #
        # PRECEDENCE: adaptive fragments are checked BEFORE budgeted because
        # `claude-opus-4` (budgeted) is a substring of `claude-opus-4-7`
        # (adaptive). Only the explicit dual-mode list permits both shapes.
        #
        # The match is a substring so it tolerates the many Bedrock model-id
        # decorations (geo prefixes `us.`/`eu.`/`ap.`, `anthropic.` provider
        # prefix, `-vN:0` version suffixes, `:200k` context suffixes).
        module ThinkingModes
          module_function

          # Minimum thinking budget Anthropic will accept (API floor).
          MINIMUM_BUDGET = 1024

          # Tokens reserved for actual model output when clamping the thinking
          # budget against max_tokens. Ensures max_tokens > budget_tokens holds
          # with room for at least a short reply.
          OUTPUT_RESERVE = 128

          # Beta header required for the adaptive effort API on Bedrock.
          EFFORT_BETA_HEADER = 'effort-2025-11-24'

          # Model-id fragments for Claude families that use the adaptive/effort
          # thinking wire: { type: 'adaptive' } + output_config: { effort: ... }.
          # These MUST be checked BEFORE BUDGETED_THINKING_FRAGMENTS because
          # 'claude-opus-4' is a substring of 'claude-opus-4-7'.
          ADAPTIVE_EFFORT_FRAGMENTS = %w[
            claude-opus-4-6
            claude-opus-4-7
            claude-opus-4-8
            claude-opus-5
            claude-sonnet-4-6
            claude-sonnet-5
          ].freeze

          # AWS still accepts manual budgets on these adaptive-capable models.
          # https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-adaptive-thinking.html
          DUAL_MODE_THINKING_FRAGMENTS = %w[claude-opus-4-6 claude-sonnet-4-6].freeze

          # Model-id fragments for Claude families that support explicit budgeted
          # extended thinking via { type: 'enabled', budget_tokens: N }.
          BUDGETED_THINKING_FRAGMENTS = %w[
            claude-3-7-sonnet
            claude-sonnet-4
            claude-opus-4
            claude-haiku-4
          ].freeze

          # Valid Bedrock effort values — the canonical effort ladder
          # (low|medium|high|xhigh|max) maps 1:1 to the Bedrock wire.
          # 'none' is NOT a valid Bedrock effort; it means "omit effort".
          VALID_EFFORTS = %w[low medium high xhigh max].freeze

          # @return [Boolean] true when the model uses adaptive thinking + effort.
          # Checked BEFORE budgeted_thinking? to ensure precedence.
          def adaptive_thinking?(model_id)
            return false if model_id.nil? || model_id.to_s.strip.empty?

            mid = model_id.to_s
            ADAPTIVE_EFFORT_FRAGMENTS.any? { |fragment| mid.include?(fragment) }
          end

          # @return [Boolean] true when the model supports { type: 'enabled', budget_tokens: N }.
          # Dual-mode 4.6 models support both; adaptive-only models must not
          # accidentally match a broad budgeted-family substring.
          def budgeted_thinking?(model_id)
            return false if model_id.nil? || model_id.to_s.strip.empty?
            return true if DUAL_MODE_THINKING_FRAGMENTS.any? { |fragment| model_id.to_s.include?(fragment) }
            return false if adaptive_thinking?(model_id)

            mid = model_id.to_s
            # Substring scan (String#include?), NOT array intersection: intersect?
            # raises TypeError on a String argument.
            BUDGETED_THINKING_FRAGMENTS.any? { |fragment| mid.include?(fragment) }
          end

          def adaptive_mode?(thinking:, model_id:)
            adaptive_thinking?(model_id) && !(thinking.budget && budgeted_thinking?(model_id))
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

            !adaptive_thinking?(model_id) && BUDGETED_THINKING_FRAGMENTS.none? { |f| mid.include?(f) }
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

          # B2: the single thinking wire-shape builder — returns the correct
          # wire shape for the model:
          # - Adaptive models: { type: 'adaptive' } (effort is a sibling field)
          # - Budgeted models: { type: 'enabled', budget_tokens: N }
          # - Non-thinking models: nil
          #
          # For adaptive models, use `adaptive_wire` to get the full descriptor
          # (thinking shape + output_config + beta header requirement).
          #
          # Budget/max_tokens reconciliation (budgeted path only): Bedrock
          # requires max_tokens > budget_tokens. When effective_max_tokens is
          # provided and the resolved budget would violate that constraint, the
          # budget is clamped to (max_tokens - OUTPUT_RESERVE) with a floor of
          # MINIMUM_BUDGET. If max_tokens is too small to accommodate even the
          # minimum budget, thinking is omitted (nil) to keep the request valid
          # rather than silently overriding the client's max_output_tokens cap.
          def thinking_wire(thinking:, model_id:, effective_max_tokens: nil, **)
            return nil unless thinking_enabled?(thinking)
            return nil if known_non_thinking?(model_id)

            # Preserve explicit budgets where supported; only resolve to an
            # adaptive effort when that is the selected model's usable mode.
            return { type: 'adaptive' } if adaptive_mode?(thinking: thinking, model_id: model_id)

            budget = thinking.resolved_budget
            if budget.nil?
              raise ArgumentError,
                    "bedrock.thinking_wire: enabled thinking has no resolvable budget_tokens for #{model_id}"
            end

            budget = reconcile_budget(budget, effective_max_tokens)
            return nil unless budget

            { type: 'enabled', budget_tokens: budget }
          end

          # Full adaptive thinking descriptor for a model that requires the
          # adaptive/effort wire. Returns a Hash with :thinking, :beta_header,
          # and optionally :output_config — or nil when thinking is not enabled
          # or the model is not adaptive.
          #
          # When resolved_effort is 'none' or nil, output_config is OMITTED
          # (the API defaults to high). The effort ladder (low|medium|high|
          # xhigh|max) is passed through 1:1 — no clamping.
          #
          # The caller is responsible for placing each key at the correct wire
          # position (invoke_model: top-level fields + anthropic_beta array;
          # Converse: additionalModelRequestFields + beta array mechanism).
          def adaptive_wire(thinking:, model_id:)
            return nil unless thinking_enabled?(thinking)
            return nil unless adaptive_mode?(thinking: thinking, model_id: model_id)

            effort = wire_effort(thinking.resolved_effort)
            result = { thinking: { type: 'adaptive' }, beta_header: EFFORT_BETA_HEADER }
            result[:output_config] = { effort: effort } if effort
            result
          end

          # Resolves the Bedrock wire effort value from a canonical
          # resolved_effort string. Returns the effort string for the wire, or
          # nil when effort should be omitted (none / nil → API default = high).
          # The canonical ladder (low|medium|high|xhigh|max) passes through 1:1.
          def wire_effort(resolved_effort)
            return nil if resolved_effort.nil? || resolved_effort == 'none'

            resolved_effort
          end

          # Clamp budget so that budget_tokens < effective_max_tokens (Bedrock
          # wire constraint). Returns the reconciled budget Integer, or nil when
          # max_tokens is too small to fit even MINIMUM_BUDGET.
          def reconcile_budget(budget, effective_max_tokens)
            return budget unless effective_max_tokens && budget >= effective_max_tokens

            clamped = [budget, effective_max_tokens - OUTPUT_RESERVE].min
            clamped = [clamped, MINIMUM_BUDGET].max

            # If after applying the floor the budget still violates the
            # constraint, thinking cannot fit — omit it to keep the request
            # valid (respects the client's explicit max_output_tokens cap).
            return nil if clamped >= effective_max_tokens

            clamped
          end
        end
      end
    end
  end
end
