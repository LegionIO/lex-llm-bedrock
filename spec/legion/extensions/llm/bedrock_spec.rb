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

CANONICAL = Legion::Extensions::Llm::Canonical

RSpec.describe Legion::Extensions::Llm::Bedrock do
  let(:provider) { described_class::Provider.new(bedrock_region: 'us-west-2', bedrock_stub_responses: true) }
  let(:message) { CANONICAL::Message.build(role: :user, content: 'hello') }
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

  after { Legion::Extensions::Llm::Inventory::Registry.reset! }

  it 'uses the shared logging helper on the extension namespace and provider' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
    expect(described_class::Provider.ancestors).to include(Legion::Logging::Helper)
  end

  it 'exposes provider defaults through the shared provider settings shape' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:bedrock)
    expect(instance).not_to have_key(:default_model)
    expect(instance.dig(:provider, :region)).to eq('us-east-2')
    expect(instance[:transport]).to eq(:aws_sdk)
    expect(instance.dig(:fleet, :respond_to_requests)).to be false
  end

  it 'exposes region-aware Bedrock endpoint helpers' do
    expect([provider.api_base, provider.completion_url, provider.stream_url, provider.models_url])
      .to eq(['https://bedrock-runtime.us-west-2.amazonaws.com', 'Converse', 'ConverseStream',
              'ListFoundationModels'])
  end

  describe 'offerings (07 C5: Registry-snapshot read path)' do
    def ssot_actor
      @ssot_actor ||= Legion::Extensions::Llm::Bedrock::Actor::DiscoveryRefresh.new
    end

    # Activates one instance under the operator config name the base read path
    # keys on (provider_instance_id), with production writer drafts.
    def activate_default_instance(models)
      registry = Legion::Extensions::Llm::Inventory::Registry
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: 'default'
      )
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = registry.claim_instance(instance_key: key, callable: Object.new, probe_request_handle: coordinator)
      probe = registry.readiness_probe_started(instance_key: key, publisher_token: token)
      offerings = models.map do |model_id|
        ssot_actor.send(
          :build_offering_draft,
          model_id: model_id,
          summary: { model_id: model_id, input_modalities: %w[TEXT], output_modalities: %w[TEXT],
                     response_streaming_supported: true },
          instance_cfg: { bedrock_region: 'us-west-2', bedrock_access_key_id: 'AKIAIOSFODNN7EXAMPLE1',
                          tier: :cloud },
          instance_key: key
        )
      end
      registry.activate_instance_snapshot(
        publisher_token: token, instance_key: key, offerings: offerings, sequence: 0, probe_token: probe
      )
    end

    it 'serves the activated inventory offerings for the instance from the snapshot' do
      activate_default_instance(%w[anthropic.claude-3-haiku-20240307-v1:0 amazon.titan-embed-text-v2:0])

      offerings = provider.discover_offerings

      expect(offerings.size).to eq(2)
      expect(offerings.map(&:model).sort).to eq(
        %w[amazon.titan-embed-text-v2:0 anthropic.claude-3-haiku-20240307-v1:0].sort
      )
      expect(offerings.first.instance_key.instance_id).to eq('default')
      expect(offerings.first).to be_a(Legion::Extensions::Llm::Inventory::OfferingRecord)
    end

    it 'returns no offerings for an instance that never claimed' do
      expect(provider.discover_offerings).to be_empty
    end

    it 'filters snapshot offerings by model' do
      activate_default_instance(%w[anthropic.claude-3-haiku-20240307-v1:0 meta.llama3-2-11b-instruct-v1:0])

      filtered = provider.discover_offerings(model: 'meta.llama3-2-11b-instruct-v1:0')

      expect(filtered.map(&:model)).to eq(%w[meta.llama3-2-11b-instruct-v1:0])
    end
  end

  it 'resolves canonical aliases to versioned Bedrock model ids' do
    expect(described_class::Provider.resolve_model_id('claude-3-haiku'))
      .to eq('anthropic.claude-3-haiku-20240307-v1:0')
    expect(described_class::Provider.resolve_model_id('unknown-model')).to eq('unknown-model')
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

  it 'reports non-live health without AWS calls' do
    expect(provider.health(live: false)).to include(provider: :bedrock, ready: true, checked: false)
    expect(bedrock_client).not_to have_received(:list_foundation_models)
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

    result = provider.chat(messages: [message], model: model, params: CANONICAL::Params.build(temperature: 0.2))

    expect(runtime_client).to have_received(:converse).with(
      hash_including(
        model_id: 'us.anthropic.claude-3-haiku-20240307-v1:0',
        messages: [{ role: 'user', content: [{ text: 'hello' }] }],
        inference_config: { temperature: 0.2, max_tokens: 2048 }
      )
    )
    expect(result).to be_a(CANONICAL::Response)
    expect([result.text, result.usage.input_tokens, result.usage.output_tokens]).to eq(['done', 3, 5])
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

  it 'streams Converse deltas through canonical chunks and returns a Canonical::Response' do
    stream = FakeConverseStream.new(text: 'hi', usage: { input_tokens: 1, output_tokens: 2 })
    allow(runtime_client).to receive(:converse_stream).and_yield(stream)
    chunks = []

    result = provider.stream(messages: [message], model: model) { |chunk| chunks << chunk }

    expect(chunks.select(&:text_delta?).map(&:delta)).to eq(%w[h i])
    expect(chunks.count(&:done?)).to eq(1)
    expect(chunks.last).to be_done
    expect(result).to be_a(CANONICAL::Response)
    expect([result.text, result.usage.input_tokens, result.usage.output_tokens]).to eq(['hi', 1, 2])
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

  it 'embeds through Titan InvokeModel and parses the documented embedding artifact' do
    allow(runtime_client).to receive(:invoke_model).and_return(
      response(body: StringIO.new(Legion::JSON.generate('embedding' => [0.1, 0.2], 'inputTextTokenCount' => 4)))
    )

    embedding = provider.embed(text: 'hello', model: 'amazon.titan-embed-text-v2:0', dimensions: 256)

    expect(runtime_client).to have_received(:invoke_model).with(
      hash_including(model_id: 'amazon.titan-embed-text-v2:0', content_type: 'application/json')
    )
    expect(embedding[:text]).to eq('hello')
    expect(embedding[:model]).to eq('amazon.titan-embed-text-v2:0')
    expect(embedding[:embedding]).to eq([0.1, 0.2])
    expect(embedding[:usage]).to be_a(CANONICAL::Usage)
    expect(embedding[:usage].input_tokens).to eq(4)
  end

  it 'does not invent a generic embedding body for non-Titan models' do
    expect do
      provider.embed(text: 'hello', model: 'cohere.embed-english-v3')
    end.to raise_error(NotImplementedError, /not standardized/)
  end

  describe 'model policy enforcement (compliance guard)' do
    def whitelist_provider
      @whitelist_provider ||= described_class::Provider.new(
        bedrock_region: 'us-west-2', bedrock_stub_responses: true, model_whitelist: %w[haiku]
      )
    end

    it 'fails closed in #chat for a model excluded by the whitelist, with no Bedrock call' do
      allow(runtime_client).to receive(:converse)

      expect do
        whitelist_provider.chat(
          messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')],
          model: 'anthropic.claude-sonnet-4-6'
        )
      end.to raise_error(Legion::Extensions::Llm::ModelNotAllowedError)
      expect(runtime_client).not_to have_received(:converse)
    end

    it 'fails closed in #stream for an excluded model, with no Bedrock call' do
      allow(runtime_client).to receive(:converse_stream)

      expect do
        whitelist_provider.stream(
          messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')],
          model: 'anthropic.claude-sonnet-4-6'
        ) do |chunk|
          chunk
        end
      end.to raise_error(Legion::Extensions::Llm::ModelNotAllowedError)
      expect(runtime_client).not_to have_received(:converse_stream)
    end

    it 'fails closed in #embed for an excluded model, with no Bedrock call' do
      allow(runtime_client).to receive(:invoke_model)

      expect { whitelist_provider.embed(text: 'hello', model: 'amazon.titan-embed-text-v2:0') }
        .to raise_error(Legion::Extensions::Llm::ModelNotAllowedError)
      expect(runtime_client).not_to have_received(:invoke_model)
    end
  end

  # Prompt caching tests (issue #8)
  # Note: Bedrock Converse API does not support cache_control on text/image/document blocks.
  # The cache_control markers were removed to fix SDK union validation errors.

  it 'renders system blocks without cache_control' do
    system_msg = CANONICAL::Message.build(role: :system, content: 'be helpful')
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
      CANONICAL::Message.build(role: :user, content: 'msg1'),
      CANONICAL::Message.build(role: :assistant, content: 'reply1'),
      CANONICAL::Message.build(role: :user, content: 'msg2'),
      CANONICAL::Message.build(role: :assistant, content: 'reply2'),
      CANONICAL::Message.build(role: :user, content: 'msg3')
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

    expect(result.usage.input_tokens).to eq(100)
    expect(result.usage.output_tokens).to eq(50)
    expect(result.usage.cache_read_tokens).to eq(80)
    expect(result.usage.cache_write_tokens).to eq(20)
  end

  it 'handles missing cache fields in converse response usage gracefully' do
    allow(runtime_client).to receive(:converse).and_return(
      response(
        output: { message: { content: [{ text: 'done' }], role: 'assistant' } },
        usage: { input_tokens: 10, output_tokens: 5 }
      )
    )

    result = provider.chat(messages: [message], model: model)

    expect(result.usage.input_tokens).to eq(10)
    expect(result.usage.output_tokens).to eq(5)
    expect(result.usage.cache_read_tokens).to be_nil
    expect(result.usage.cache_write_tokens).to be_nil
  end

  it 'parses cache metrics from streaming response metadata' do
    stream = FakeConverseStream.new(text: 'ok', usage: { input_tokens: 30, output_tokens: 10,
                                                         cache_read_input_tokens: 20,
                                                         cache_creation_input_tokens: 10 })
    allow(runtime_client).to receive(:converse_stream).and_yield(stream)

    result = provider.stream(messages: [message], model: model)

    expect(result.usage.cache_read_tokens).to eq(20)
    expect(result.usage.cache_write_tokens).to eq(10)
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
    allow(publisher).to receive(:schedule).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
