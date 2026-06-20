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
  let(:provider) { described_class::Provider.new(bedrock_region: 'us-west-2', bedrock_stub_responses: true) }
  let(:message) { Legion::Extensions::Llm::Message.new(role: :user, content: 'hello') }
  let(:model) do
    Legion::Extensions::Llm::Model::Info.new(id: 'anthropic.claude-3-haiku-20240307-v1:0', provider: :bedrock,
                                             metadata: { max_output_tokens: 2048 })
  end
  let(:runtime_client) { instance_double(Aws::BedrockRuntime::Client) }
  let(:bedrock_client) { instance_double(Aws::Bedrock::Client) }

  before do
    allow(Aws::BedrockRuntime::Client).to receive(:new).and_return(runtime_client)
    allow(Aws::Bedrock::Client).to receive(:new).and_return(bedrock_client)
    allow(bedrock_client).to receive(:list_foundation_models)
  end

  it 'uses the shared logging helper on the extension namespace and provider' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
    expect(described_class::Provider.ancestors).to include(Legion::Logging::Helper)
  end

  it 'exposes provider defaults through the shared provider settings shape' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:bedrock)
    expect(instance[:default_model]).to eq('anthropic.claude-sonnet-4')
    expect(instance.dig(:provider, :region)).to eq('us-east-2')
    expect(instance[:transport]).to eq(:aws_sdk)
    expect(instance.dig(:fleet, :respond_to_requests)).to be false
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

  it 'uses explicit geo prefixing independent of AWS region' do
    expect(described_class::Provider.inference_profile_id('anthropic.claude-opus-4-7', geo_prefix: 'eu',
                                                                                       region: 'us-west-2'))
      .to eq('eu.anthropic.claude-opus-4-7')
  end

  it 'replaces an existing geo prefix with the configured prefix' do
    expect(described_class::Provider.inference_profile_id('us.anthropic.claude-opus-4-7', geo_prefix: 'ap'))
      .to eq('ap.anthropic.claude-opus-4-7')
  end

  it 'resolves anthropic sonnet 4 alias to a versioned Bedrock model id' do
    expect(described_class::Provider.resolve_model_id('anthropic.claude-sonnet-4'))
      .to eq('anthropic.claude-sonnet-4-20250514-v1:0')
  end

  it 'uses provider instance transport and tier in offerings' do
    configured = described_class::Provider.new(
      bedrock_region: 'us-west-2',
      bedrock_stub_responses: true,
      transport: :rabbitmq,
      tier: :fleet
    )
    offering = configured.offering_for(model: 'claude-3-haiku', model_family: :anthropic)

    expect(offering.to_h).to include(transport: :rabbitmq, tier: :fleet)
  end

  it 'builds live offerings from ListFoundationModels summaries' do
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
  end

  it 'reports non-live health without AWS calls' do
    expect(provider.health(live: false)).to include(provider: :bedrock, ready: true, checked: false)
    expect(bedrock_client).not_to have_received(:list_foundation_models)
  end

  it 'publishes live readiness metadata asynchronously through the registry publisher' do
    stub_registry_publisher
    allow(bedrock_client).to receive(:list_foundation_models).and_return(response(model_summaries: []))

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'returns Model::Info from list_models with capabilities from modalities' do
    stub_registry_publisher
    allow(bedrock_client).to receive(:list_foundation_models).and_return(
      response(
        model_summaries: [
          {
            model_id: 'anthropic.claude-3-haiku-20240307-v1:0',
            provider_name: 'Anthropic',
            input_modalities: %w[TEXT IMAGE],
            output_modalities: ['TEXT'],
            response_streaming_supported: true
          },
          {
            model_id: 'amazon.titan-embed-text-v2:0',
            provider_name: 'Amazon',
            input_modalities: ['TEXT'],
            output_modalities: ['EMBEDDING'],
            response_streaming_supported: false
          }
        ]
      )
    )

    models = provider.list_models

    chat_model = models.find { |m| m.id.include?('claude') }
    embed_model = models.find { |m| m.id.include?('titan-embed') }

    expect(chat_model).to be_a(Legion::Extensions::Llm::Model::Info)
    expect(chat_model.provider).to eq(:bedrock)
    expect(chat_model.capabilities).to include(:completion, :streaming, :vision)
    expect(chat_model.modalities_input).to include(:text, :image)
    expect(chat_model.modalities_output).to include(:text)

    expect(embed_model.capabilities).to include(:embedding)
    expect(embed_model.modalities_output).to include(:embedding)
  end

  it 'publishes discovered models asynchronously through the registry publisher' do
    stub_registry_publisher
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

    provider.discover_offerings(live: true)

    expect(registry_publisher).to have_received(:publish_models_async).at_least(:once)
  end

  it 'builds sanitized lex-llm registry events for Bedrock model availability' do
    model_info = Legion::Extensions::Llm::Model::Info.new(
      id: 'anthropic.claude-3-haiku-20240307-v1:0',
      name: 'claude-3-haiku',
      provider: :bedrock,
      capabilities: %i[completion streaming vision],
      modalities_input: %w[text image],
      modalities_output: %w[text]
    )
    events = capture_registry_events([model_info], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:bedrock)
    expect(events.first.to_h.dig(:offering, :model)).to eq('anthropic.claude-3-haiku-20240307-v1:0')
  end

  it 'renders Converse requests and parses assistant responses' do
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } },
               usage: { input_tokens: 3, output_tokens: 5 })
    )

    result = provider.chat(messages: [message], model: model, temperature: 0.2)

    expect(runtime_client).to have_received(:converse).with(
      hash_including(
        model_id: 'us.anthropic.claude-3-haiku-20240307-v1:0',
        messages: [{ role: 'user', content: [{ text: 'hello' }] }],
        inference_config: { temperature: 0.2, max_tokens: 2048 }
      )
    )
    expect([result.content, result.input_tokens, result.output_tokens]).to eq(['done', 3, 5])
  end

  it 'renders Bedrock tool configuration for Converse' do
    # Use a non-Anthropic model to test Converse tool rendering directly
    # (Anthropic models with tools route through invoke_model)
    llama_model = Legion::Extensions::Llm::Model::Info.new(
      id: 'meta.llama3-2-11b-instruct-v1:0', provider: :bedrock, metadata: { max_output_tokens: 2048 }
    )
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } })
    )

    provider.chat(messages: [message], model: llama_model, tools: { lookup: tool('lookup') },
                  tool_prefs: { choice: :lookup })

    expect(runtime_client).to have_received(:converse).with(hash_including(tool_config: lookup_tool_config))
  end

  it 'streams Converse deltas through chunks and returns an accumulated message' do
    stream = FakeConverseStream.new(text: 'hi', usage: { input_tokens: 1, output_tokens: 2 })
    allow(runtime_client).to receive(:converse_stream).and_yield(stream)
    chunks = []

    result = provider.stream(messages: [message], model: model) { |chunk| chunks << chunk }

    expect(chunks.map(&:content)).to eq(%w[h i])
    expect([result.content, result.input_tokens, result.output_tokens]).to eq(['hi', 1, 2])
  end

  it 'counts tokens through the Bedrock CountTokens Converse input shape' do
    allow(runtime_client).to receive(:count_tokens).and_return(response(input_tokens: 7))

    result = provider.count_tokens(messages: [message], model: model)

    expect(runtime_client).to have_received(:count_tokens).with(
      model_id: 'us.anthropic.claude-3-haiku-20240307-v1:0',
      input: { converse: { messages: [{ role: 'user', content: [{ text: 'hello' }] }] } }
    )
    expect(result).to include(input_tokens: 7)
  end

  it 'embeds through Titan InvokeModel and parses Titan embedding responses' do
    allow(runtime_client).to receive(:invoke_model).and_return(
      response(body: StringIO.new(Legion::JSON.generate('embedding' => [0.1, 0.2], 'inputTextTokenCount' => 4)))
    )

    embedding = provider.embed(text: 'hello', model: 'amazon.titan-embed-text-v2:0', dimensions: 256)

    expect(runtime_client).to have_received(:invoke_model).with(
      hash_including(model_id: 'amazon.titan-embed-text-v2:0', content_type: 'application/json')
    )
    expect([embedding.vectors, embedding.input_tokens]).to eq([[0.1, 0.2], 4])
  end

  it 'does not invent a generic embedding body for non-Titan models' do
    expect do
      provider.embed(text: 'hello', model: 'cohere.embed-english-v3')
    end.to raise_error(NotImplementedError, /not standardized/)
  end

  describe 'model policy enforcement (compliance guard)' do
    let(:provider) do
      described_class::Provider.new(bedrock_region: 'us-west-2', bedrock_stub_responses: true,
                                    model_whitelist: %w[haiku])
    end

    it 'fails closed in #chat for a model excluded by the whitelist, with no Bedrock call' do
      allow(runtime_client).to receive(:converse)

      expect { provider.chat(messages: [{ role: 'user', content: 'hi' }], model: 'anthropic.claude-sonnet-4-6') }
        .to raise_error(Legion::Extensions::Llm::ModelNotAllowedError)
      expect(runtime_client).not_to have_received(:converse)
    end

    it 'fails closed in #stream for an excluded model, with no Bedrock call' do
      allow(runtime_client).to receive(:converse_stream)

      expect do
        provider.stream(messages: [{ role: 'user', content: 'hi' }], model: 'anthropic.claude-sonnet-4-6') do |chunk|
          chunk
        end
      end.to raise_error(Legion::Extensions::Llm::ModelNotAllowedError)
      expect(runtime_client).not_to have_received(:converse_stream)
    end

    it 'fails closed in #embed for an excluded model, with no Bedrock call' do
      allow(runtime_client).to receive(:invoke_model)

      expect { provider.embed(text: 'hello', model: 'amazon.titan-embed-text-v2:0') }
        .to raise_error(Legion::Extensions::Llm::ModelNotAllowedError)
      expect(runtime_client).not_to have_received(:invoke_model)
    end
  end

  describe '.resolve_default_model (policy-aware default)' do
    before { allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).with(:extensions, :llm, :bedrock).and_return(nil) }

    it 'keeps a configured default when no policy is set' do
      expect(described_class.resolve_default_model(default_model: 'amazon.nova-pro-v1:0')).to eq('amazon.nova-pro-v1:0')
    end

    it 'falls back to DEFAULT_MODEL when none configured and no policy' do
      expect(described_class.resolve_default_model({})).to eq(described_class::DEFAULT_MODEL)
    end

    it 'drops a configured default the whitelist forbids rather than forcing it' do
      expect(described_class.resolve_default_model(default_model: 'anthropic.claude-sonnet-4',
                                                   model_whitelist: %w[haiku])).to be_nil
    end

    it 'reads the provider-level whitelist when the instance config has none' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                                            .and_return({ model_whitelist: %w[haiku] })
      expect(described_class.resolve_default_model(default_model: 'anthropic.claude-sonnet-4')).to be_nil
    end
  end

  # Prompt caching tests (issue #8)
  # Note: Bedrock Converse API does not support cache_control on text/image/document blocks.
  # The cache_control markers were removed to fix SDK union validation errors.

  it 'renders system blocks without cache_control' do
    system_msg = Legion::Extensions::Llm::Message.new(role: :system, content: 'be helpful')
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } })
    )

    provider.chat(messages: [system_msg, message], model: model)

    expect(runtime_client).to have_received(:converse).with(
      hash_including(
        system: [{ text: 'be helpful' }]
      )
    )
  end

  it 'renders tool definitions without cache_control' do
    # Use a non-Anthropic model to test Converse tool definitions directly
    llama_model = Legion::Extensions::Llm::Model::Info.new(
      id: 'meta.llama3-2-11b-instruct-v1:0', provider: :bedrock, metadata: { max_output_tokens: 2048 }
    )
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } })
    )

    provider.chat(messages: [message], model: llama_model, tools: { lookup: tool('lookup') },
                  tool_prefs: { choice: :lookup })

    expect(runtime_client).to have_received(:converse).with(
      hash_including(
        tool_config: hash_including(
          tools: [
            hash_including(tool_spec: hash_including(name: 'lookup'))
          ]
        )
      )
    )
  end

  it 'renders message blocks without cache_control' do
    msgs = [
      Legion::Extensions::Llm::Message.new(role: :user, content: 'msg1'),
      Legion::Extensions::Llm::Message.new(role: :assistant, content: 'reply1'),
      Legion::Extensions::Llm::Message.new(role: :user, content: 'msg2'),
      Legion::Extensions::Llm::Message.new(role: :assistant, content: 'reply2'),
      Legion::Extensions::Llm::Message.new(role: :user, content: 'msg3')
    ]
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } })
    )

    provider.chat(messages: msgs, model: model)

    expect(runtime_client).to have_received(:converse).with(
      hash_including(
        messages: [
          hash_including(content: [hash_including(text: 'msg1')]),
          hash_including(content: [hash_including(text: 'reply1')]),
          hash_including(content: [hash_including(text: 'msg2')]),
          hash_including(content: [hash_including(text: 'reply2')]),
          hash_including(content: [hash_including(text: 'msg3')])
        ]
      )
    )
  end

  it 'skips cache_control on the last message when there is only one message' do
    allow(runtime_client).to receive(:converse).and_return(
      response(output: { message: { content: [{ text: 'done' }], role: 'assistant' } })
    )

    provider.chat(messages: [message], model: model)

    expect(runtime_client).to have_received(:converse).with(
      hash_including(
        messages: [hash_including(content: [hash_not_including(:cache_control)])]
      )
    )
  end

  it 'parses cached_input_tokens and cache_creation_tokens from converse response usage' do
    allow(runtime_client).to receive(:converse).and_return(
      response(
        output: { message: { content: [{ text: 'done' }], role: 'assistant' } },
        usage: { input_tokens: 100, output_tokens: 50,
                 cache_read_input_tokens: 80, cache_creation_input_tokens: 20 }
      )
    )

    result = provider.chat(messages: [message], model: model)

    expect(result.input_tokens).to eq(100)
    expect(result.output_tokens).to eq(50)
    expect(result.cached_tokens).to eq(80)
    expect(result.cache_creation_tokens).to eq(20)
  end

  it 'handles missing cache fields in converse response usage gracefully' do
    allow(runtime_client).to receive(:converse).and_return(
      response(
        output: { message: { content: [{ text: 'done' }], role: 'assistant' } },
        usage: { input_tokens: 10, output_tokens: 5 }
      )
    )

    result = provider.chat(messages: [message], model: model)

    expect(result.input_tokens).to eq(10)
    expect(result.output_tokens).to eq(5)
    expect(result.cached_tokens).to be_nil
    expect(result.cache_creation_tokens).to be_nil
  end

  it 'parses cache metrics from streaming response metadata' do
    stream = FakeConverseStream.new(text: 'ok', usage: { input_tokens: 30, output_tokens: 10,
                                                         cache_read_input_tokens: 20,
                                                         cache_creation_input_tokens: 10 })
    allow(runtime_client).to receive(:converse_stream).and_yield(stream)

    result = provider.stream(messages: [message], model: model)

    expect(result.cached_tokens).to eq(20)
    expect(result.cache_creation_tokens).to eq(10)
  end

  def response(values)
    Class.new do
      define_method(:initialize) { |payload| @payload = payload }
      define_method(:to_h) { @payload }
    end.new(values)
  end

  def registry_publisher
    @registry_publisher ||= instance_double(Legion::Extensions::Llm::RegistryPublisher)
  end

  def stub_registry_publisher
    allow(described_class).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_readiness_async)
    allow(registry_publisher).to receive(:publish_models_async)
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

  def capture_registry_events(models, readiness:)
    publisher = Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :bedrock)
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
