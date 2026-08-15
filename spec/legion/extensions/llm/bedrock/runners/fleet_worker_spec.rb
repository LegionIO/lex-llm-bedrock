# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/bedrock/runners/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Bedrock::Runners::FleetWorker do
  let(:message) do
    {
      request_id: 'req-1', correlation_id: 'corr-1', idempotency_key: 'idem-1',
      operation: 'chat', provider: 'bedrock', provider_instance: 'us-east-1/ak:01234567',
      model: 'us.anthropic.claude-sonnet-4-6', params: { messages: [] },
      reply_to: 'legion.fleet.replies', message_context: {}, caller: 'test',
      trace_context: {}, signed_token: 'tok', timeout_seconds: 60,
      expires_at: '2026-01-01T00:01:00Z', protocol_version: 2
    }
  end
  let(:instances) { { 'us-east-1/ak:01234567' => { fleet: { respond_to_requests: true } } } }

  it 'uses the shared logging helper' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
  end

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    allow(Legion::Extensions::Llm::Bedrock).to receive(:discover_instances).and_return(instances)
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    result = described_class.handle_fleet_request(**message)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: message,
      provider_family: :bedrock,
      provider_class: Legion::Extensions::Llm::Bedrock::Provider,
      provider_instances: satisfy { |resolver| resolver.call == instances }
    )
  end
end
