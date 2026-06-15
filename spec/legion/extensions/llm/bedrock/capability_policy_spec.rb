# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do # rubocop:disable RSpec/SpecFilePathFormat
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

  describe 'model metadata from AWS summary' do
    let(:summary) do
      {
        model_id: 'anthropic.claude-sonnet-4-20250514-v1:0',
        provider_name: 'Anthropic',
        response_streaming_supported: true,
        input_modalities: %w[TEXT IMAGE],
        output_modalities: %w[TEXT]
      }
    end

    it 'derives streaming and vision from model summary with :model_metadata source' do
      offering = provider.send(:offering_from_summary, summary)

      expect(offering.capabilities).to include(:streaming)
      expect(offering.capabilities).to include(:vision)
      expect(offering.capability_sources[:streaming]).to eq({ value: true, source: :model_metadata })
      expect(offering.capability_sources[:vision]).to eq({ value: true, source: :model_metadata })
    end

    it 'derives embeddings from output modalities with :model_metadata source' do
      embed_summary = {
        model_id: 'amazon.titan-embed-text-v2:0',
        provider_name: 'Amazon',
        response_streaming_supported: false,
        input_modalities: %w[TEXT],
        output_modalities: %w[EMBEDDING]
      }

      offering = provider.send(:offering_from_summary, embed_summary)

      expect(offering.capabilities).to include(:embeddings)
      expect(offering.capability_sources[:embeddings]).to eq({ value: true, source: :model_metadata })
    end

    it 'resolves tools from provider_envelope when not in model metadata' do
      offering = provider.send(:offering_from_summary, summary)

      expect(offering.capabilities).to include(:tools)
      expect(offering.capability_sources[:tools]).to eq({ value: true, source: :provider_envelope })
    end
  end

  describe 'provider-root override' do
    let(:summary) do
      {
        model_id: 'anthropic.claude-sonnet-4-20250514-v1:0',
        provider_name: 'Anthropic',
        response_streaming_supported: true,
        input_modalities: %w[TEXT IMAGE],
        output_modalities: %w[TEXT]
      }
    end

    it 'provider config tools_flag: false overrides provider_envelope' do
      allow(credential_sources).to receive(:setting)
        .with(:extensions, :llm, :bedrock)
        .and_return({ tools_flag: false })

      offering = provider.send(:offering_from_summary, summary)

      expect(offering.capabilities).not_to include(:tools)
      expect(offering.capability_sources[:tools]).to eq({ value: false, source: :provider_override })
    end
  end

  describe 'instance override' do
    let(:summary) do
      {
        model_id: 'anthropic.claude-sonnet-4-20250514-v1:0',
        provider_name: 'Anthropic',
        response_streaming_supported: true,
        input_modalities: %w[TEXT IMAGE],
        output_modalities: %w[TEXT]
      }
    end

    it 'instance config capabilities hash overrides lower layers' do
      instance_config = base_config.merge(capabilities: { tools: true, thinking: false })
      p = described_class.allocate
      config = Legion::Extensions::Llm::HashConfig.new(instance_config)
      p.instance_variable_set(:@config, config)

      offering = p.send(:offering_from_summary, summary)

      expect(offering.capabilities).to include(:tools)
      expect(offering.capabilities).not_to include(:thinking)
      expect(offering.capability_sources[:tools]).to eq({ value: true, source: :instance_override })
      expect(offering.capability_sources[:thinking]).to eq({ value: false, source: :instance_override })
    end
  end

  describe 'model override' do
    let(:summary) do
      {
        model_id: 'anthropic.claude-sonnet-4-20250514-v1:0',
        provider_name: 'Anthropic',
        response_streaming_supported: true,
        input_modalities: %w[TEXT IMAGE],
        output_modalities: %w[TEXT]
      }
    end

    it 'model config thinking_flag: true resolves with :model_override source' do
      model_config = base_config.merge(
        models: { 'anthropic.claude-sonnet-4-20250514-v1:0' => { thinking_flag: true } }
      )
      p = described_class.allocate
      config = Legion::Extensions::Llm::HashConfig.new(model_config)
      p.instance_variable_set(:@config, config)

      offering = p.send(:offering_from_summary, summary)

      expect(offering.capabilities).to include(:thinking)
      expect(offering.capability_sources[:thinking]).to eq({ value: true, source: :model_override })
    end
  end
end
