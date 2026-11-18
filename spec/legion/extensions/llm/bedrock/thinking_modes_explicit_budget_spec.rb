# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/translator'

# Both 4.6 models support manual budgets as well as adaptive thinking. The
# recorded Claude request supplied budget_tokens: 1024 and max_tokens: 2048;
# translating it to adaptive/low permits the model to skip thinking entirely.
RSpec.describe Legion::Extensions::Llm::Bedrock::ThinkingModes do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:thinking) { canonical::Thinking::Config.build(budget: 1024) }
  let(:params) { canonical::Params.build(max_tokens: 2048) }
  let(:messages) { [canonical::Message.build(role: :user, content: 'Say hello in exactly 3 words.')] }
  let(:provider) { Legion::Extensions::Llm::Bedrock::Provider.allocate }

  targets = %i[invoke_model converse]
  %w[anthropic.claude-sonnet-4-6 us.anthropic.claude-opus-4-6-v1].each do |model|
    context "with #{model}" do
      it 'keeps the explicit budget in the shared thinking-mode owner' do
        expect(described_class.budgeted_thinking?(model)).to be true
        expect(described_class.thinking_wire(thinking: thinking, model_id: model, effective_max_tokens: 2048))
          .to eq(type: 'enabled', budget_tokens: 1024)
        expect(described_class.adaptive_wire(thinking: thinking, model_id: model)).to be_nil
        expect(thinking.effort).to be_nil
      end

      it 'preserves the budget through provider InvokeModel rendering' do
        body = provider.send(:build_invoke_model_body, messages: messages, model: model,
                                                       thinking: thinking, params: params)

        expect(body[:thinking]).to eq(type: 'enabled', budget_tokens: 1024)
        expect(body[:max_tokens]).to eq(2048)
        expect(body).not_to have_key(:output_config)
      end

      it 'preserves the budget through provider Converse rendering' do
        fields = provider.send(:bedrock_additional_fields, thinking, model: model)

        expect(fields[:thinking]).to eq(type: 'enabled', budget_tokens: 1024)
        expect(fields).not_to have_key(:output_config)
      end

      targets.each do |target|
        it "preserves the budget through canonical #{target} rendering" do
          translator = Legion::Extensions::Llm::Bedrock::Translator.new(region: 'us-east-1', geo_prefix: 'us')
          request = canonical::Request.build(messages: messages, thinking: thinking, params: params,
                                             metadata: { model: model })
          wire = translator.render_request(request, target: target)
          fields = target == :converse ? wire[:additional_model_request_fields] : wire

          expect(fields[:thinking]).to eq(type: 'enabled', budget_tokens: 1024)
          expect(fields).not_to have_key(:output_config)
        end
      end

      it 'continues to use adaptive mode for an effort-only request' do
        effort = canonical::Thinking::Config.build(effort: 'high')
        descriptor = described_class.adaptive_wire(thinking: effort, model_id: model)

        expect(descriptor[:thinking]).to eq(type: 'adaptive')
        expect(descriptor[:output_config]).to eq(effort: 'high')
      end
    end
  end
end
