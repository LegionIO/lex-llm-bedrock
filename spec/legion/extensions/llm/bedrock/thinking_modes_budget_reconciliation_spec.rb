# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/thinking_modes'
require 'legion/extensions/llm/bedrock/render_defaults'

# Budget/max_tokens reconciliation: Bedrock requires max_tokens > budget_tokens.
# When the SSOT-resolved budget (e.g. effort=high → 16384) exceeds the
# effective max_tokens (e.g. client sends max_output_tokens=2048), the budget
# must be clamped to keep the wire request valid. These specs prove:
# 1. budget_tokens < max_tokens in the rendered wire when resolved budget >= max_tokens
# 2. budget_tokens >= MINIMUM_BUDGET (1024) after clamping
# 3. thinking is omitted when max_tokens is too small for any valid budget
# 4. no reference to the deleted Canonical::Params#max_thinking_tokens
RSpec.describe Legion::Extensions::Llm::Bedrock::ThinkingModes do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:thinking_modes) { described_class }
  let(:opus_model) { 'anthropic.claude-opus-4-5-20251101-v1:0' }

  describe '.reconcile_budget' do
    it 'returns budget unchanged when effective_max_tokens is nil' do
      result = thinking_modes.reconcile_budget(16_384, nil)

      expect(result).to eq(16_384)
    end

    it 'returns budget unchanged when budget < effective_max_tokens' do
      result = thinking_modes.reconcile_budget(2048, 4096)

      expect(result).to eq(2048)
    end

    it 'clamps budget to max_tokens - OUTPUT_RESERVE when budget >= max_tokens' do
      result = thinking_modes.reconcile_budget(16_384, 2048)

      expect(result).to eq(2048 - thinking_modes::OUTPUT_RESERVE)
      expect(result).to be < 2048
      expect(result).to be >= thinking_modes::MINIMUM_BUDGET
    end

    it 'respects the MINIMUM_BUDGET floor when clamping' do
      # max_tokens = 1200 → clamped = 1200 - 128 = 1072 (above floor)
      result = thinking_modes.reconcile_budget(16_384, 1200)

      expect(result).to eq(1072)
      expect(result).to be >= thinking_modes::MINIMUM_BUDGET
    end

    it 'applies MINIMUM_BUDGET floor when max_tokens - reserve < 1024' do
      # max_tokens = 1100 → clamped = 1100 - 128 = 972, floored to 1024
      # 1024 < 1100 → valid
      result = thinking_modes.reconcile_budget(16_384, 1100)

      expect(result).to eq(thinking_modes::MINIMUM_BUDGET)
      expect(result).to be < 1100
    end

    it 'returns nil when max_tokens is too small to fit MINIMUM_BUDGET' do
      # max_tokens = 1024 → clamped = 1024 - 128 = 896, floored to 1024
      # 1024 >= 1024 → can't fit, return nil
      result = thinking_modes.reconcile_budget(16_384, 1024)

      expect(result).to be_nil
    end

    it 'returns nil when max_tokens is smaller than MINIMUM_BUDGET' do
      result = thinking_modes.reconcile_budget(16_384, 500)

      expect(result).to be_nil
    end
  end

  describe '.thinking_wire budget/max_tokens reconciliation' do
    it 'clamps budget_tokens < max_tokens when resolved budget exceeds effective max_tokens' do
      # The core failure case: effort=high (16384) with max_tokens=2048
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: opus_model,
        effective_max_tokens: 2048
      )

      expect(result).to be_a(Hash)
      expect(result[:type]).to eq('enabled')
      expect(result[:budget_tokens]).to be < 2048
      expect(result[:budget_tokens]).to be >= thinking_modes::MINIMUM_BUDGET
      expect(result[:budget_tokens]).to eq(2048 - thinking_modes::OUTPUT_RESERVE)
    end

    it 'does not clamp when budget < effective_max_tokens' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(budget: 2048),
        model_id: opus_model,
        effective_max_tokens: 4096
      )

      expect(result).to eq({ type: 'enabled', budget_tokens: 2048 })
    end

    it 'does not clamp when effective_max_tokens is nil (converse without explicit max)' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: opus_model,
        effective_max_tokens: nil
      )

      expect(result).to eq({ type: 'enabled', budget_tokens: 16_384 })
    end

    it 'omits thinking when max_tokens is too small for any valid budget' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: opus_model,
        effective_max_tokens: 1024
      )

      expect(result).to be_nil
    end

    it 'clamps to DEFAULT_MAX_TOKENS - OUTPUT_RESERVE when budget exceeds the 4096 default' do
      # Simulates invoke_model with no explicit max_tokens (defaults to 4096)
      default_mt = Legion::Extensions::Llm::Bedrock::RenderDefaults::DEFAULT_MAX_TOKENS
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: opus_model,
        effective_max_tokens: default_mt
      )

      expect(result[:budget_tokens]).to eq(default_mt - thinking_modes::OUTPUT_RESERVE)
      expect(result[:budget_tokens]).to be < default_mt
    end
  end

  describe '.thinking_wire does not reference max_thinking_tokens' do
    it 'does not call max_thinking_tokens on a non-nil params object' do
      # Canonical::Params no longer has max_thinking_tokens (deleted in lex-llm 0.8.3).
      # Verify that thinking_wire does not attempt to call it.
      params = canonical::Params.build(max_tokens: 4096)

      expect(params).not_to respond_to(:max_thinking_tokens)

      # This must not raise NoMethodError — budget comes solely from resolved_budget
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(budget: 2048),
        model_id: opus_model,
        params: params,
        effective_max_tokens: 4096
      )

      expect(result).to eq({ type: 'enabled', budget_tokens: 2048 })
    end
  end
end
