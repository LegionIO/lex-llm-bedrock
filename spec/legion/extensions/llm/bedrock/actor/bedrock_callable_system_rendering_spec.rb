# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/callable'

RSpec.describe Legion::Extensions::Llm::Bedrock::Actor::BedrockCallable do
  it 'renders a folded leading system message in the native Bedrock system field' do
    runtime_client = instance_double(Aws::BedrockRuntime::Client)
    allow(runtime_client).to receive(:converse).and_return(
      output: { message: { content: [{ text: 'done' }], role: 'assistant' } }, usage: {}
    )
    provider = Legion::Extensions::Llm::Bedrock::Provider.new(
      bedrock_region: 'us-east-1', bedrock_stub_responses: true
    )
    provider.instance_variable_set(:@runtime_client, runtime_client)
    callable = described_class.new(instance_cfg: {}, logger: Logger.new(File::NULL))
    callable.instance_variable_set(:@provider, provider)
    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'D14 system'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]

    # The 0.8.0 callable boundary takes messages positionally (base
    # Provider#chat / fleet WorkerExecution form).
    callable.chat(messages, model: 'meta.llama3-test')

    expect(runtime_client).to have_received(:converse).with(
      hash_including(system: [{ text: 'D14 system' }])
    )
  end
end
