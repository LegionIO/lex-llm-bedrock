# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/translator'

# Bug 2: the thinking payload shape must match what each model actually supports.
# - Models that support explicit budgeted thinking -> { type: 'enabled', budget_tokens: N }
# - Models that do NOT support thinking -> OMIT the thinking field (nil), never { type: 'adaptive' }
#   because Bedrock rejects adaptive on those models (ValidationException -> HTTP 500).
RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do
  let(:base_config) do
    {
      bedrock_region: 'us-east-1',
      bedrock_stub_responses: true,
      bearer_token: 'test-token'
    }
  end

  let(:provider) do
    p = described_class.allocate
    p.instance_variable_set(:@config, Legion::Extensions::Llm::HashConfig.new(base_config))
    p
  end

  describe '#invoke_model_thinking' do
    it 'returns { type: enabled, budget_tokens } for a budgeted-thinking model (opus-4-5)' do
      result = provider.send(:invoke_model_thinking,
                             model: 'anthropic.claude-opus-4-5-20251101-v1:0',
                             thinking: { budget_tokens: 2048 })

      expect(result).to eq({ type: 'enabled', budget_tokens: 2048 })
    end

    it 'returns { type: enabled, budget_tokens } for claude-sonnet-4' do
      result = provider.send(:invoke_model_thinking,
                             model: 'anthropic.claude-sonnet-4-20250514-v1:0',
                             thinking: { budget_tokens: 1500 })

      expect(result).to eq({ type: 'enabled', budget_tokens: 1500 })
    end

    it 'OMITS thinking (nil), never adaptive, for a non-thinking model (claude-3-haiku)' do
      result = provider.send(:invoke_model_thinking,
                             model: 'anthropic.claude-3-haiku-20240307-v1:0',
                             thinking: { budget_tokens: 2048 })

      expect(result).to be_nil
    end
  end

  describe '#build_invoke_model_body' do
    it 'omits the thinking key entirely for a non-thinking model' do
      body = provider.send(:build_invoke_model_body,
                           messages: [], model: 'anthropic.claude-3-haiku-20240307-v1:0',
                           tools: nil, tool_prefs: nil,
                           thinking: { budget_tokens: 2048 },
                           params: Legion::Extensions::Llm::Canonical::Params.build(max_tokens: 100))

      expect(body).not_to have_key(:thinking)
    end

    it 'includes an enabled thinking block for a thinking model' do
      body = provider.send(:build_invoke_model_body,
                           messages: [], model: 'anthropic.claude-opus-4-5-20251101-v1:0',
                           tools: nil, tool_prefs: nil,
                           thinking: { budget_tokens: 2048 },
                           params: Legion::Extensions::Llm::Canonical::Params.build(max_tokens: 100))

      expect(body[:thinking]).to eq({ type: 'enabled', budget_tokens: 2048 })
    end
  end

  describe Legion::Extensions::Llm::Bedrock::Translator do
    subject(:translator) { described_class.new(region: 'us-east-1', geo_prefix: 'us') }

    let(:canonical) { Legion::Extensions::Llm::Canonical }

    def request_for(model_id)
      canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        thinking: { effort: 'high', budget: 2048 },
        metadata: { model: model_id }
      )
    end

    describe '#build_invoke_thinking' do
      it 'returns enabled+budget for a budgeted-thinking model (opus-4-5)' do
        result = translator.send(:build_invoke_thinking,
                                 request_for('anthropic.claude-opus-4-5-20251101-v1:0'))

        expect(result).to eq({ type: 'enabled', budget_tokens: 2048 })
      end

      it 'returns enabled+budget for claude-sonnet-4' do
        result = translator.send(:build_invoke_thinking,
                                 request_for('anthropic.claude-sonnet-4-20250514-v1:0'))

        expect(result).to eq({ type: 'enabled', budget_tokens: 2048 })
      end

      it 'OMITS thinking (nil), never adaptive, for a non-thinking model (claude-3-haiku)' do
        result = translator.send(:build_invoke_thinking,
                                 request_for('anthropic.claude-3-haiku-20240307-v1:0'))

        expect(result).to be_nil
      end
    end

    describe '#render_invoke_model' do
      it 'omits the thinking key for a non-thinking model' do
        wire = translator.render_request(request_for('anthropic.claude-3-haiku-20240307-v1:0'),
                                         target: :invoke_model)

        expect(wire).not_to have_key(:thinking)
      end

      it 'includes enabled thinking for a thinking model' do
        wire = translator.render_request(request_for('anthropic.claude-opus-4-5-20251101-v1:0'),
                                         target: :invoke_model)

        expect(wire[:thinking]).to eq({ type: 'enabled', budget_tokens: 2048 })
      end
    end
  end
end
