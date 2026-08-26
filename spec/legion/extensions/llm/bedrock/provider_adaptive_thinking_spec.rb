# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/translator'

# Adaptive thinking wire rendering: the Provider's invoke_model and Converse
# paths must emit the correct wire shape for adaptive models (opus-4-6/4-7/4-8,
# sonnet-4-6):
# - invoke_model: top-level thinking: { type: 'adaptive' }, output_config: { effort: },
#   anthropic_beta array includes 'effort-2025-11-24'
# - Converse: additionalModelRequestFields carries thinking, output_config, anthropic_beta
#
# Budgeted models (opus-4-5, sonnet-4 base) remain on the existing
# { type: 'enabled', budget_tokens: N } path.
RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do # adaptive thinking wire
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  context 'with provider dispatch paths' do
    let(:base_config) do
      { bedrock_region: 'us-east-1', bedrock_stub_responses: true, bearer_token: 'test-token' }
    end

    let(:provider) do
      p = described_class.allocate
      p.instance_variable_set(:@config, Legion::Extensions::Llm::HashConfig.new(base_config))
      p
    end

    describe '#build_invoke_model_body' do
      it 'emits adaptive thinking + output_config + beta header for opus-4-7' do
        body = provider.send(:build_invoke_model_body,
                             messages: [], model: 'anthropic.claude-opus-4-7-20260701-v1:0',
                             tools: nil, tool_prefs: nil,
                             thinking: canonical::Thinking::Config.build(effort: 'high'),
                             params: canonical::Params.build(max_tokens: 4096))

        expect(body[:thinking]).to eq({ type: 'adaptive' })
        expect(body[:output_config]).to eq({ effort: 'high' })
        expect(body[:anthropic_beta]).to include('effort-2025-11-24')
        expect(body[:thinking]).not_to have_key(:budget_tokens)
      end

      it 'emits effort=low for a low-effort config on adaptive model' do
        body = provider.send(:build_invoke_model_body,
                             messages: [], model: 'us.anthropic.claude-opus-4-8-20260801-v1:0',
                             tools: nil, tool_prefs: nil,
                             thinking: canonical::Thinking::Config.build(effort: 'low'),
                             params: canonical::Params.build(max_tokens: 4096))

        expect(body[:thinking]).to eq({ type: 'adaptive' })
        expect(body[:output_config]).to eq({ effort: 'low' })
        expect(body[:anthropic_beta]).to include('effort-2025-11-24')
      end

      it 'derives effort from budget for adaptive model (budget-only config)' do
        body = provider.send(:build_invoke_model_body,
                             messages: [], model: 'anthropic.claude-opus-4-7-20260701-v1:0',
                             tools: nil, tool_prefs: nil,
                             thinking: canonical::Thinking::Config.build(budget: 8192),
                             params: canonical::Params.build(max_tokens: 4096))

        expect(body[:thinking]).to eq({ type: 'adaptive' })
        # budget 8192 -> resolved_effort = 'medium'
        expect(body[:output_config]).to eq({ effort: 'medium' })
        expect(body[:anthropic_beta]).to include('effort-2025-11-24')
      end

      it 'does NOT emit adaptive wire for budgeted model (opus-4-5)' do
        body = provider.send(:build_invoke_model_body,
                             messages: [], model: 'anthropic.claude-opus-4-5-20251101-v1:0',
                             tools: nil, tool_prefs: nil,
                             thinking: canonical::Thinking::Config.build(budget: 2048),
                             params: canonical::Params.build(max_tokens: 4096))

        expect(body[:thinking]).to eq({ type: 'enabled', budget_tokens: 2048 })
        expect(body).not_to have_key(:output_config)
        expect(body).not_to have_key(:anthropic_beta)
      end

      it 'omits thinking entirely when thinking is disabled on adaptive model' do
        body = provider.send(:build_invoke_model_body,
                             messages: [], model: 'anthropic.claude-opus-4-7-20260701-v1:0',
                             tools: nil, tool_prefs: nil,
                             thinking: canonical::Thinking::Config.build(enabled: false),
                             params: canonical::Params.build(max_tokens: 4096))

        expect(body).not_to have_key(:thinking)
        expect(body).not_to have_key(:output_config)
        expect(body).not_to have_key(:anthropic_beta)
      end
    end

    describe '#bedrock_additional_fields' do
      it 'emits adaptive thinking + output_config + beta header for opus-4-7' do
        result = provider.send(:bedrock_additional_fields,
                               canonical::Thinking::Config.build(effort: 'high'),
                               model: 'anthropic.claude-opus-4-7-20260701-v1:0')

        expect(result[:thinking]).to eq({ type: 'adaptive' })
        expect(result[:output_config]).to eq({ effort: 'high' })
        expect(result[:anthropic_beta]).to eq(['effort-2025-11-24'])
      end

      it 'emits effort=medium for medium-effort config on sonnet-4-6' do
        result = provider.send(:bedrock_additional_fields,
                               canonical::Thinking::Config.build(effort: 'medium'),
                               model: 'anthropic.claude-sonnet-4-6-20260601-v1:0')

        expect(result[:thinking]).to eq({ type: 'adaptive' })
        expect(result[:output_config]).to eq({ effort: 'medium' })
        expect(result[:anthropic_beta]).to eq(['effort-2025-11-24'])
      end

      it 'returns budgeted wire for opus-4-5 (not adaptive)' do
        result = provider.send(:bedrock_additional_fields,
                               canonical::Thinking::Config.build(budget: 2048),
                               model: 'anthropic.claude-opus-4-5-20251101-v1:0')

        expect(result).to eq({ thinking: { type: 'enabled', budget_tokens: 2048 } })
        expect(result).not_to have_key(:output_config)
        expect(result).not_to have_key(:anthropic_beta)
      end

      it 'returns nil when thinking is disabled' do
        result = provider.send(:bedrock_additional_fields,
                               canonical::Thinking::Config.build(enabled: false),
                               model: 'anthropic.claude-opus-4-7-20260701-v1:0')

        expect(result).to be_nil
      end
    end
  end

  describe Legion::Extensions::Llm::Bedrock::Translator do
    subject(:translator) { described_class.new(region: 'us-east-1', geo_prefix: 'us') }

    def request_for(model_id, effort: 'high', budget: nil)
      thinking_opts = budget ? { effort: effort, budget: budget } : { effort: effort }
      canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        thinking: thinking_opts,
        metadata: { model: model_id }
      )
    end

    describe 'invoke_model adaptive rendering' do
      it 'emits adaptive thinking + output_config + beta header for opus-4-7' do
        wire = translator.render_request(request_for('anthropic.claude-opus-4-7-20260701-v1:0'),
                                         target: :invoke_model)

        expect(wire[:thinking]).to eq({ type: 'adaptive' })
        expect(wire[:output_config]).to eq({ effort: 'high' })
        expect(wire[:anthropic_beta]).to include('effort-2025-11-24')
        expect(wire[:thinking]).not_to have_key(:budget_tokens)
      end

      it 'maps effort=low correctly for invoke_model' do
        wire = translator.render_request(request_for('anthropic.claude-opus-4-8-20260801-v1:0', effort: 'low'),
                                         target: :invoke_model)

        expect(wire[:thinking]).to eq({ type: 'adaptive' })
        expect(wire[:output_config]).to eq({ effort: 'low' })
      end

      it 'maps effort=xhigh to high for invoke_model' do
        wire = translator.render_request(request_for('anthropic.claude-sonnet-4-6-20260601-v1:0', effort: 'xhigh'),
                                         target: :invoke_model)

        expect(wire[:output_config]).to eq({ effort: 'high' })
      end

      it 'still emits budgeted wire for opus-4-5 on invoke_model' do
        wire = translator.render_request(request_for('anthropic.claude-opus-4-5-20251101-v1:0',
                                                     effort: 'high', budget: 2048),
                                         target: :invoke_model)

        expect(wire[:thinking]).to eq({ type: 'enabled', budget_tokens: 2048 })
        expect(wire).not_to have_key(:output_config)
        expect(wire).not_to have_key(:anthropic_beta)
      end
    end

    describe 'converse adaptive rendering' do
      it 'emits adaptive fields in additional_model_request_fields for opus-4-7' do
        wire = translator.render_request(request_for('anthropic.claude-opus-4-7-20260701-v1:0'),
                                         target: :converse)

        additional = wire[:additional_model_request_fields]
        expect(additional).not_to be_nil
        expect(additional[:thinking]).to eq({ type: 'adaptive' })
        expect(additional[:output_config]).to eq({ effort: 'high' })
        expect(additional[:anthropic_beta]).to include('effort-2025-11-24')
      end

      it 'emits budgeted fields in additional_model_request_fields for sonnet-4 base' do
        wire = translator.render_request(request_for('anthropic.claude-sonnet-4-20250514-v1:0',
                                                     effort: 'high', budget: 2048),
                                         target: :converse)

        additional = wire[:additional_model_request_fields]
        expect(additional).not_to be_nil
        expect(additional[:thinking]).to eq({ type: 'enabled', budget_tokens: 2048 })
        expect(additional).not_to have_key(:output_config)
        expect(additional).not_to have_key(:anthropic_beta)
      end
    end
  end
end
