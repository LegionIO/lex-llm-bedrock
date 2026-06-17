# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/provider'

# Path B regression specs: chunks must be yielded to the caller's block from
# both bedrock streaming paths. Fake event streams register handlers and fire
# them after registration returns, exactly like the AWS SDK does mid-call.
RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do
  subject(:provider) { described_class.allocate }

  # Minimal stand-in for Aws::BedrockRuntime::EventStreams::*
  let(:fake_stream_class) do
    Class.new do
      def initialize = @handlers = {}

      def method_missing(name, *args, &block)
        return super unless name.to_s.start_with?('on_')

        (@handlers[name] ||= []) << block
        nil
      end

      def respond_to_missing?(name, _include_private = false)
        name.to_s.start_with?('on_')
      end

      def fire(name, event)
        Array(@handlers[name]).each { |handler| handler.call(event) }
      end
    end
  end

  describe '#stream_converse' do
    it 'yields text delta chunks to the block' do
      fake = fake_stream_class.new
      client = Object.new
      client.define_singleton_method(:converse_stream) do |**_request, &block|
        block.call(fake)
        delta_event = Struct.new(:delta).new(Struct.new(:text).new('Hello'))
        fake.fire(:on_content_block_delta_event, delta_event)
        fake.fire(:on_message_stop_event, Struct.new(:stop_reason).new('end_turn'))
      end
      provider.define_singleton_method(:runtime_client) { client }

      chunks = []
      message = provider.send(:stream_converse, { messages: [] }, 'claude-x') { |chunk| chunks << chunk }

      expect(chunks.map { |c| c.content.to_s }).to eq(['Hello'])
      expect(message.content).to eq('Hello')
    end

    it 'extracts text from reasoning deltas without raising' do
      fake = fake_stream_class.new
      client = Object.new
      reasoning_delta = Struct.new(:text, :reasoning).new(nil, Struct.new(:text).new('pondering'))
      client.define_singleton_method(:converse_stream) do |**_request, &block|
        block.call(fake)
        fake.fire(:on_content_block_start_event,
                  Struct.new(:start).new(Struct.new(:thinking, :reasoning).new(nil, true)))
        fake.fire(:on_content_block_delta_event, Struct.new(:delta).new(reasoning_delta))
      end
      provider.define_singleton_method(:runtime_client) { client }

      message = nil
      expect do
        message = provider.send(:stream_converse, { messages: [] }, 'claude-x') { |_c| nil }
      end.not_to raise_error
      expect(message.thinking.to_s).to include('pondering')
    end
  end

  describe '#invoke_model_stream' do
    let(:events) do
      [
        { 'type' => 'message_start', 'message' => { 'usage' => { 'input_tokens' => 5 } } },
        { 'type' => 'content_block_start', 'content_block' => { 'type' => 'text' } },
        { 'type' => 'content_block_delta', 'delta' => { 'type' => 'text_delta', 'text' => 'Hello' } },
        { 'type' => 'content_block_delta', 'delta' => { 'type' => 'text_delta', 'text' => ' world' } },
        { 'type' => 'message_delta', 'delta' => { 'stop_reason' => 'end_turn' } }
      ]
    end

    before do
      provider.define_singleton_method(:region) { 'us-east-1' }
      provider.define_singleton_method(:config) { Struct.new(:bearer_token).new(nil) }
    end

    it 'yields text delta chunks to the block' do
      fake = fake_stream_class.new
      payload = events.map { |event| Legion::JSON.dump(event) }.join("\n")
      client = Object.new
      client.define_singleton_method(:invoke_model_with_response_stream) do |**_request, &block|
        block.call(fake)
        fake.fire(:on_chunk_event, Struct.new(:bytes).new(payload))
      end
      provider.define_singleton_method(:runtime_client) { client }

      chunks = []
      message = provider.send(
        :invoke_model_stream,
        messages: [{ role: :user, content: 'hi' }], model: 'anthropic.claude-sonnet-4-20250514-v1:0',
        temperature: nil, max_tokens: 100, tools: {}, tool_prefs: nil, thinking: nil
      ) { |chunk| chunks << chunk }

      expect(chunks.map { |c| c.content.to_s }).to eq(['Hello', ' world'])
      expect(message.content).to eq('Hello world')
    end

    it 're-raises handler errors instead of swallowing them' do
      fake = fake_stream_class.new
      client = Object.new
      client.define_singleton_method(:invoke_model_with_response_stream) do |**_request, &block|
        block.call(fake)
        fake.fire(:on_chunk_event, Struct.new(:bytes).new(+'{"type":"content_block_delta"}'))
      end
      provider.define_singleton_method(:runtime_client) { client }
      provider.define_singleton_method(:handle_invoke_model_stream_json) { |*_args| raise ArgumentError, 'boom' }

      expect do
        provider.send(
          :invoke_model_stream,
          messages: [], model: 'anthropic.claude-sonnet-4-20250514-v1:0',
          temperature: nil, max_tokens: 100, tools: {}, tool_prefs: nil, thinking: nil
        ) { |_c| nil }
      end.to raise_error(ArgumentError, 'boom')
    end
  end
end
