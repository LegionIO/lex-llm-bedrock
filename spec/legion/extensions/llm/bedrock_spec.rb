# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

class FakeConverseStream
  def initialize(text:, usage:)
    @text = text
    @usage = usage
  end

  def on_content_block_delta_event
    @text.each_char { |char| yield Struct.new(:delta).new({ text: char }) }
  end

  def on_metadata_event
    yield Struct.new(:usage).new(@usage)
  end
end

RSpec.describe Legion::Extensions::Llm::Bedrock do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:message) { Legion::Extensions::Llm::Message.new(role: :user, content: 'hello') }
  let(:model) do
    Legion::Extensions::Llm::Model::Info.new(id: 'anthropic.claude-3-haiku-20240307-v1:0', provider: :bedrock,
                                             max_output_tokens: 2048)
  end
  let(:runtime_client) { instance_double(Aws::BedrockRuntime::Client) }
  let(:bedrock_client) { instance_double(Aws::Bedrock::Client) }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.bedrock_region = 'us-west-2'
      config.bedrock_stub_responses = true
    end

    allow(Aws::BedrockRuntime::Client).to receive(:new).and_return(runtime_client)
    allow(Aws::Bedrock::Client).to receive(:new).and_return(bedrock_client)
    allow(bedrock_client).to receive(:list_foundation_models)
  end

  it 'exposes provider defaults with offline discovery and inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:bedrock)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:discovery, :live)).to be false
    expect(settings.dig(:instances, :default, :region)).to eq('us-east-1')
    expect(settings.dig(:instances, :default, :credentials, :provider)).to eq('aws-sdk-default-chain')
  end

  it 'registers the Legion::Extensions::Llm provider class' do
    expect(Legion::Extensions::Llm::Provider.resolve(:bedrock)).to eq(described_class::Provider)
  end

  it 'exposes region-aware Bedrock endpoint helpers' do
    expect([provider.api_base, provider.completion_url, provider.stream_url, provider.models_url])
      .to eq(['https://bedrock-runtime.us-west-2.amazonaws.com', 'Converse', 'ConverseStream',
              'ListFoundationModels'])
  end

  it 'maps offline offerings with Bedrock family and inferred model families' do
    offerings = provider.discover_offerings(live: false)
    claude = offerings.find { |offering| offering.model.start_with?('anthropic.') }
    embed = offerings.find(&:embedding?)

    expect(claude.provider_family).to eq(:bedrock)
    expect(claude.metadata).to include(model_family: :anthropic, alias: 'claude-3-haiku')
    expect(claude.capabilities).to include(:chat, :streaming)
    expect(embed.model).to eq('amazon.titan-embed-text-v2:0')
    expect(embed.usage_type).to eq(:embedding)
  end

  it 'accepts canonical aliases and explicit model families for offerings' do
    offering = provider.offering_for(model: 'claude-3-haiku', model_family: :anthropic, instance_id: :west)

    expect(offering.to_h).to include(provider_family: :bedrock, instance_id: :west,
                                     model: 'anthropic.claude-3-haiku-20240307-v1:0')
    expect(offering.metadata).to include(model_family: :anthropic, alias: 'claude-3-haiku')
  end

  it 'builds live offerings from ListFoundationModels summaries' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_offerings_async)
    allow(bedrock_client).to receive(:list_foundation_models).and_return(
      response(
        model_summaries: [
          {
            model_id: 'meta.llama3-2-11b-instruct-v1:0',
            provider_name: 'Meta',
            input_modalities: ['TEXT'],
            output_modalities: ['TEXT'],
            response_streaming_supported: true
          }
        ]
      )
    )

    offerings = provider.discover_offerings(live: true, by_provider: 'Meta')

    expect(Aws::Bedrock::Client).to have_received(:new).with(hash_including(region: 'us-west-2'))
    expect(bedrock_client).to have_received(:list_foundation_models).with(by_provider: 'Meta')
    expect(offerings.first.metadata).to include(model_family: :meta)
    expect(registry_publisher).to have_received(:publish_offerings_async)
      .with(offerings, readiness: hash_including(provider: :bedrock, live: false))
  end

  it 'reports non-live health without AWS calls' do
    expect(provider.health(live: false)).to include(provider: :bedrock, ready: true, checked: false)
    expect(bedrock_client).not_to have_received(:list_foundation_models)
  end

  it 'publishes live readiness metadata asynchronously through the registry publisher' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_readiness_async)
    allow(bedrock_client).to receive(:list_foundation_models).and_return(response(model_summaries: []))

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'builds sanitized lex-llm registry events for Bedrock offering availability' do
    offering = provider.discover_offerings(live: false).first
    events = capture_registry_events([offering], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:bedrock)
    expect(events.first.to_h.dig(:offering, :model)).to eq('anthropic.claude-3-haiku-20240307-v1:0')
  end

  it 'renders Converse requests and parses assistant responses' do
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } },
               usage: { input_tokens: 3, output_tokens: 5 })
    )

    result = provider.chat([message], model: model, temperature: 0.2)

    expect(runtime_client).to have_received(:converse).with(
      hash_including(
        model_id: 'anthropic.claude-3-haiku-20240307-v1:0',
        messages: [{ role: 'user', content: [{ text: 'hello' }] }],
        inference_config: { temperature: 0.2, max_tokens: 2048 }
      )
    )
    expect([result.content, result.input_tokens, result.output_tokens]).to eq(['done', 3, 5])
  end

  it 'renders Bedrock tool configuration for Converse' do
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } })
    )

    provider.chat([message], model: model, tools: { lookup: tool('lookup') }, tool_prefs: { choice: :lookup })

    expect(runtime_client).to have_received(:converse).with(hash_including(tool_config: lookup_tool_config))
  end

  it 'streams Converse deltas through chunks and returns an accumulated message' do
    stream = FakeConverseStream.new(text: 'hi', usage: { input_tokens: 1, output_tokens: 2 })
    allow(runtime_client).to receive(:converse_stream).and_yield(stream)
    chunks = []

    result = provider.stream([message], model: model) { |chunk| chunks << chunk }

    expect(chunks.map(&:content)).to eq(%w[h i])
    expect([result.content, result.input_tokens, result.output_tokens]).to eq(['hi', 1, 2])
  end

  it 'counts tokens through the Bedrock CountTokens Converse input shape' do
    allow(runtime_client).to receive(:count_tokens).and_return(response(input_tokens: 7))

    result = provider.count_tokens([message], model: model)

    expect(runtime_client).to have_received(:count_tokens).with(
      model_id: 'anthropic.claude-3-haiku-20240307-v1:0',
      input: { converse: { messages: [{ role: 'user', content: [{ text: 'hello' }] }] } }
    )
    expect(result).to include(input_tokens: 7)
  end

  it 'embeds through Titan InvokeModel and parses Titan embedding responses' do
    allow(runtime_client).to receive(:invoke_model).and_return(
      response(body: StringIO.new(Legion::JSON.generate('embedding' => [0.1, 0.2], 'inputTextTokenCount' => 4)))
    )

    embedding = provider.embed('hello', model: 'amazon.titan-embed-text-v2:0', dimensions: 256)

    expect(runtime_client).to have_received(:invoke_model).with(
      hash_including(model_id: 'amazon.titan-embed-text-v2:0', content_type: 'application/json')
    )
    expect([embedding.vectors, embedding.input_tokens]).to eq([[0.1, 0.2], 4])
  end

  it 'does not invent a generic embedding body for non-Titan models' do
    expect do
      provider.embed('hello', model: 'cohere.embed-english-v3')
    end.to raise_error(NotImplementedError, /not standardized/)
  end

  def response(values)
    Class.new do
      define_method(:initialize) { |payload| @payload = payload }
      define_method(:to_h) { @payload }
    end.new(values)
  end

  def registry_publisher
    @registry_publisher ||= instance_double(described_class::RegistryPublisher)
  end

  def tool(name)
    Struct.new(:name, :description, :params_schema).new(name, 'look up a value', { type: 'object', properties: {} })
  end

  def lookup_tool_config
    {
      tools: [
        {
          tool_spec: {
            name: 'lookup',
            description: 'look up a value',
            input_schema: { json: { type: 'object', properties: {} } }
          }
        }
      ],
      tool_choice: { tool: { name: 'lookup' } }
    }
  end

  def capture_registry_events(offerings, readiness:)
    publisher = described_class::RegistryPublisher.new
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_offerings_async(offerings, readiness:)
    events
  end
end
