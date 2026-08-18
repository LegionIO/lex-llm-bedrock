# frozen_string_literal: true

require 'spec_helper'

# Bug 1: Claude models that support extended thinking must advertise the :thinking
# capability so the router's thinking filter can protect them. The truth lives in
# the shared lex-llm catalog (models.json, `reasoning` -> :thinking); bedrock
# discovery must surface it via CapabilityPolicy's :provider_catalog source.
RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do
  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }
  let(:base_config) do
    {
      bedrock_region: 'us-east-1',
      bedrock_endpoint: nil,
      bedrock_access_key_id: nil,
      bedrock_secret_access_key: nil,
      bedrock_session_token: nil,
      bedrock_profile: nil,
      bedrock_stub_responses: true,
      bearer_token: 'test-token'
    }
  end

  let(:provider) do
    p = described_class.allocate
    config = Legion::Extensions::Llm::HashConfig.new(base_config)
    p.instance_variable_set(:@config, config)
    p
  end

  before do
    allow(credential_sources).to receive(:setting).and_return(nil)
  end

  def summary_for(model_id)
    {
      model_id: model_id,
      provider_name: 'Anthropic',
      response_streaming_supported: true,
      input_modalities: %w[TEXT IMAGE],
      output_modalities: %w[TEXT]
    }
  end

  describe 'thinking capability from shared catalog' do
    it 'advertises :thinking for a thinking-capable Claude 4 model (opus-4-5)' do
      offering = provider.send(:offering_from_summary,
                               summary_for('anthropic.claude-opus-4-5-20251101-v1:0'))

      expect(offering.capabilities).to include(:thinking)
      expect(offering.capability_sources[:thinking][:value]).to be true
      expect(offering.capability_sources[:thinking][:source]).to eq(:provider_catalog)
    end

    it 'advertises :thinking for claude-sonnet-4' do
      offering = provider.send(:offering_from_summary,
                               summary_for('anthropic.claude-sonnet-4-20250514-v1:0'))

      expect(offering.capabilities).to include(:thinking)
    end

    it 'does NOT advertise :thinking for a non-thinking Claude 3 model (claude-3-haiku)' do
      offering = provider.send(:offering_from_summary,
                               summary_for('anthropic.claude-3-haiku-20240307-v1:0'))

      expect(offering.capabilities).not_to include(:thinking)
    end

    it 'lets an instance override still win over the catalog' do
      instance_config = base_config.merge(capabilities: { thinking: false })
      p = described_class.allocate
      p.instance_variable_set(:@config, Legion::Extensions::Llm::HashConfig.new(instance_config))

      offering = p.send(:offering_from_summary,
                        summary_for('anthropic.claude-opus-4-5-20251101-v1:0'))

      expect(offering.capabilities).not_to include(:thinking)
      expect(offering.capability_sources[:thinking][:source]).to eq(:instance_override)
    end
  end
end
