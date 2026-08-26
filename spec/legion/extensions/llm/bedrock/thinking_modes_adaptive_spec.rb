# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/thinking_modes'
require 'legion/extensions/llm/bedrock/render_defaults'

# Adaptive/effort thinking wire: newer Bedrock Claude models REJECT
# { type: 'enabled', budget_tokens: N } and require the adaptive/effort wire:
#   thinking: { type: 'adaptive' }
#   output_config: { effort: <low|medium|high|xhigh|max> }
#   anthropic_beta: ['effort-2025-11-24']
# The effort ladder passes through 1:1 from the canonical resolved_effort.
# 'none' or nil effort -> output_config is OMITTED (API defaults to high).
RSpec.describe Legion::Extensions::Llm::Bedrock::ThinkingModes do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:thinking_modes) { described_class }

  describe '.adaptive_thinking?' do
    it 'returns true for claude-opus-4-6' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-opus-4-6-20260601-v1:0')).to be true
    end

    it 'returns true for claude-opus-4-7' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-opus-4-7-20260701-v1:0')).to be true
    end

    it 'returns true for claude-opus-4-8' do
      expect(thinking_modes.adaptive_thinking?('us.anthropic.claude-opus-4-8-20260801-v1:0')).to be true
    end

    it 'returns true for claude-opus-5' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-opus-5-20270101-v1:0')).to be true
    end

    it 'returns true for claude-sonnet-4-6' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-sonnet-4-6-20260601-v1:0')).to be true
    end

    it 'returns true for claude-sonnet-5' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-sonnet-5-20270101-v1:0')).to be true
    end

    it 'returns false for opus-4-5 (budgeted, not adaptive)' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-opus-4-5-20251101-v1:0')).to be false
    end

    it 'returns false for sonnet-4 base (budgeted, not adaptive)' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-sonnet-4-20250514-v1:0')).to be false
    end

    it 'returns false for opus-4 base (budgeted, not adaptive)' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-opus-4-20250514-v1:0')).to be false
    end

    it 'returns false for nil model_id' do
      expect(thinking_modes.adaptive_thinking?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(thinking_modes.adaptive_thinking?('')).to be false
    end
  end

  describe '.budgeted_thinking? (precedence)' do
    it 'returns false for adaptive models even though they substring-match budgeted fragments' do
      # claude-opus-4-7 contains 'claude-opus-4' which is in BUDGETED_THINKING_FRAGMENTS
      # but the adaptive check wins.
      expect(thinking_modes.budgeted_thinking?('anthropic.claude-opus-4-7-20260701-v1:0')).to be false
    end

    it 'returns false for opus-5 (adaptive, not budgeted)' do
      expect(thinking_modes.budgeted_thinking?('anthropic.claude-opus-5-20270101-v1:0')).to be false
    end

    it 'returns true for opus-4-5 (budgeted, not adaptive)' do
      expect(thinking_modes.budgeted_thinking?('anthropic.claude-opus-4-5-20251101-v1:0')).to be true
    end

    it 'returns true for sonnet-4 base (budgeted)' do
      expect(thinking_modes.budgeted_thinking?('anthropic.claude-sonnet-4-20250514-v1:0')).to be true
    end

    it 'returns true for opus-4 base (budgeted)' do
      expect(thinking_modes.budgeted_thinking?('anthropic.claude-opus-4-20250514-v1:0')).to be true
    end
  end

  describe '.known_non_thinking?' do
    it 'returns false for adaptive models (they DO support thinking)' do
      expect(thinking_modes.known_non_thinking?('anthropic.claude-opus-4-7-20260701-v1:0')).to be false
    end

    it 'returns false for budgeted models (they support thinking)' do
      expect(thinking_modes.known_non_thinking?('anthropic.claude-opus-4-5-20251101-v1:0')).to be false
    end

    it 'returns true for a non-thinking claude model (claude-3-haiku)' do
      expect(thinking_modes.known_non_thinking?('anthropic.claude-3-haiku-20240307-v1:0')).to be true
    end
  end

  describe '.wire_effort (direct passthrough)' do
    it 'passes low through directly' do
      expect(thinking_modes.wire_effort('low')).to eq('low')
    end

    it 'passes medium through directly' do
      expect(thinking_modes.wire_effort('medium')).to eq('medium')
    end

    it 'passes high through directly' do
      expect(thinking_modes.wire_effort('high')).to eq('high')
    end

    it 'passes xhigh through directly (no clamping to high)' do
      expect(thinking_modes.wire_effort('xhigh')).to eq('xhigh')
    end

    it 'passes max through directly (no clamping to high)' do
      expect(thinking_modes.wire_effort('max')).to eq('max')
    end

    it 'returns nil for none (not a valid Bedrock effort)' do
      expect(thinking_modes.wire_effort('none')).to be_nil
    end

    it 'returns nil for nil (omit output_config, API defaults to high)' do
      expect(thinking_modes.wire_effort(nil)).to be_nil
    end
  end

  describe '.thinking_wire for adaptive models' do
    it 'returns { type: adaptive } with NO budget_tokens for an adaptive model' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).to eq({ type: 'adaptive' })
      expect(result).not_to have_key(:budget_tokens)
    end

    it 'returns { type: adaptive } regardless of budget in the config' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(budget: 16_384),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).to eq({ type: 'adaptive' })
      expect(result).not_to have_key(:budget_tokens)
    end

    it 'returns { type: adaptive } for opus-5' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: 'anthropic.claude-opus-5-20270101-v1:0'
      )

      expect(result).to eq({ type: 'adaptive' })
    end

    it 'returns { type: adaptive } for sonnet-5' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'medium'),
        model_id: 'anthropic.claude-sonnet-5-20270101-v1:0'
      )

      expect(result).to eq({ type: 'adaptive' })
    end

    it 'returns nil when thinking is disabled on an adaptive model' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(enabled: false),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).to be_nil
    end
  end

  describe '.thinking_wire for budgeted models (unchanged behavior)' do
    it 'returns { type: enabled, budget_tokens } for opus-4-5' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(budget: 2048),
        model_id: 'anthropic.claude-opus-4-5-20251101-v1:0'
      )

      expect(result).to eq({ type: 'enabled', budget_tokens: 2048 })
    end

    it 'resolves effort to budget via the SSOT map for budgeted models' do
      result = thinking_modes.thinking_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: 'anthropic.claude-sonnet-4-20250514-v1:0'
      )

      expect(result).to eq({ type: 'enabled', budget_tokens: 16_384 })
    end
  end

  describe '.adaptive_wire' do
    it 'returns the full adaptive descriptor with effort=high' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).to eq(
        thinking: { type: 'adaptive' },
        output_config: { effort: 'high' },
        beta_header: 'effort-2025-11-24'
      )
    end

    it 'passes effort=low through directly' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'low'),
        model_id: 'us.anthropic.claude-opus-4-8-20260801-v1:0'
      )

      expect(result[:output_config]).to eq({ effort: 'low' })
    end

    it 'passes effort=medium through directly' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'medium'),
        model_id: 'anthropic.claude-sonnet-4-6-20260601-v1:0'
      )

      expect(result[:output_config]).to eq({ effort: 'medium' })
    end

    it 'passes effort=xhigh through directly (NOT clamped to high)' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'xhigh'),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result[:output_config]).to eq({ effort: 'xhigh' })
    end

    it 'passes effort=max through directly (NOT clamped to high)' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'max'),
        model_id: 'anthropic.claude-opus-5-20270101-v1:0'
      )

      expect(result[:output_config]).to eq({ effort: 'max' })
    end

    it 'omits output_config when effort is none (API defaults to high)' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'none'),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result[:thinking]).to eq({ type: 'adaptive' })
      expect(result[:beta_header]).to eq('effort-2025-11-24')
      expect(result).not_to have_key(:output_config)
    end

    it 'derives effort from budget via resolved_effort for a budget-only config' do
      # budget: 1024 -> resolved_effort = 'low' -> effort = 'low'
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(budget: 1024),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result[:output_config]).to eq({ effort: 'low' })
    end

    it 'derives high effort from high budget' do
      # budget: 16384 -> resolved_effort = 'high' -> effort = 'high'
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(budget: 16_384),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result[:output_config]).to eq({ effort: 'high' })
    end

    it 'returns nil when thinking is disabled' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(enabled: false),
        model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).to be_nil
    end

    it 'returns nil for a budgeted model (not adaptive)' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'high'),
        model_id: 'anthropic.claude-opus-4-5-20251101-v1:0'
      )

      expect(result).to be_nil
    end

    it 'returns nil when thinking config is nil' do
      result = thinking_modes.adaptive_wire(
        thinking: nil, model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).to be_nil
    end

    it 'works for opus-5 with effort=max' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'max'),
        model_id: 'anthropic.claude-opus-5-20270101-v1:0'
      )

      expect(result[:thinking]).to eq({ type: 'adaptive' })
      expect(result[:output_config]).to eq({ effort: 'max' })
      expect(result[:beta_header]).to eq('effort-2025-11-24')
    end

    it 'works for sonnet-5 with effort=xhigh' do
      result = thinking_modes.adaptive_wire(
        thinking: canonical::Thinking::Config.build(effort: 'xhigh'),
        model_id: 'anthropic.claude-sonnet-5-20270101-v1:0'
      )

      expect(result[:thinking]).to eq({ type: 'adaptive' })
      expect(result[:output_config]).to eq({ effort: 'xhigh' })
      expect(result[:beta_header]).to eq('effort-2025-11-24')
    end
  end

  describe 'precedence: claude-opus-4-7 is adaptive NOT budgeted' do
    let(:thinking) { canonical::Thinking::Config.build(effort: 'high') }

    it 'adaptive_thinking? returns true' do
      expect(thinking_modes.adaptive_thinking?('anthropic.claude-opus-4-7-20260701-v1:0')).to be true
    end

    it 'budgeted_thinking? returns false (adaptive wins)' do
      expect(thinking_modes.budgeted_thinking?('anthropic.claude-opus-4-7-20260701-v1:0')).to be false
    end

    it 'thinking_wire returns adaptive shape (no budget_tokens)' do
      result = thinking_modes.thinking_wire(
        thinking: thinking, model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).to eq({ type: 'adaptive' })
    end

    it 'adaptive_wire returns the full descriptor' do
      result = thinking_modes.adaptive_wire(
        thinking: thinking, model_id: 'anthropic.claude-opus-4-7-20260701-v1:0'
      )

      expect(result).not_to be_nil
      expect(result[:thinking]).to eq({ type: 'adaptive' })
      expect(result[:output_config]).to eq({ effort: 'high' })
      expect(result[:beta_header]).to eq('effort-2025-11-24')
    end
  end
end
