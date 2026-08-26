# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/provider'

# Path B regression specs: canonical chunks must be yielded to the caller's
# block from both bedrock streaming paths, and the accumulated state must
# build a Canonical::Response. Fake event streams register handlers and fire
# them after registration returns, exactly like the AWS SDK does mid-call.
RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do
  subject(:provider) { described_class.allocate }

  let(:canonical) { Legion::Extensions::Llm::Canonical }

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
    it 'yields canonical text delta chunks and ends in a done chunk' do
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
      response = provider.send(:stream_converse, { messages: [] }, 'claude-x') { |chunk| chunks << chunk }

      expect(chunks).to all(be_a(canonical::Chunk))
      expect(chunks.select(&:text_delta?).map(&:delta)).to eq(['Hello'])
      expect(chunks.count(&:done?)).to eq(1)
      expect(chunks.last).to be_done
      expect(chunks.last.stop_reason).to eq(:end_turn)
      expect(response).to be_a(canonical::Response)
      expect(response.text).to eq('Hello')
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

      response = nil
      expect do
        response = provider.send(:stream_converse, { messages: [] }, 'claude-x') { |_c| nil }
      end.not_to raise_error
      expect(response).to be_a(canonical::Response)
      expect(response.thinking.content).to include('pondering')
    end

    it 'yields thinking_delta chunks for reasoning deltas (B12: the invoke/converse asymmetry is deleted)' do
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

      chunks = []
      provider.send(:stream_converse, { messages: [] }, 'claude-x') { |c| chunks << c }

      thinking_chunks = chunks.select(&:thinking_delta?)
      expect(thinking_chunks.map(&:delta)).to eq(['pondering'])
    end

    # B7: an explicit provider error event is a dispatch failure — raised
    # before any done chunk; a truncated stream is never a completed response.
    it 'raises StreamError before the done chunk when an error event fires' do
      fake = fake_stream_class.new
      client = Object.new
      error_event = Struct.new(:error).new(Struct.new(:type, :message).new('error', 'model died'))
      client.define_singleton_method(:converse_stream) do |**_request, &block|
        block.call(fake)
        fake.fire(:on_content_block_delta_event, Struct.new(:delta).new(Struct.new(:text).new('partial')))
        fake.fire(:on_error_event, error_event)
      end
      provider.define_singleton_method(:runtime_client) { client }

      chunks = []
      expect do
        provider.send(:stream_converse, { messages: [] }, 'claude-x') { |c| chunks << c }
      end.to raise_error(Legion::Extensions::Llm::Bedrock::StreamError, /model died/)
      expect(chunks.count(&:done?)).to eq(0)
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

    it 'yields canonical text delta chunks and ends in a done chunk' do
      fake = fake_stream_class.new
      payload = events.map { |event| Legion::JSON.dump(event) }.join("\n")
      client = Object.new
      client.define_singleton_method(:invoke_model_with_response_stream) do |**_request, &block|
        block.call(fake)
        fake.fire(:on_chunk_event, Struct.new(:bytes).new(payload))
      end
      provider.define_singleton_method(:runtime_client) { client }

      chunks = []
      response = provider.send(
        :invoke_model_stream,
        messages: [canonical::Message.build(role: :user, content: 'hi')],
        model: 'anthropic.claude-sonnet-4-20250514-v1:0',
        tools: {}, tool_prefs: nil, thinking: nil,
        params: canonical::Params.build(max_tokens: 100)
      ) { |chunk| chunks << chunk }

      expect(chunks).to all(be_a(canonical::Chunk))
      expect(chunks.select(&:text_delta?).map(&:delta)).to eq(['Hello', ' world'])
      expect(chunks.count(&:done?)).to eq(1)
      expect(chunks.last).to be_done
      expect(response).to be_a(canonical::Response)
      expect(response.text).to eq('Hello world')
      expect(response.usage.input_tokens).to eq(5)
      expect(response.stop_reason).to eq(:end_turn)
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
          tools: {}, tool_prefs: nil, thinking: nil,
          params: canonical::Params.build(max_tokens: 100)
        ) { |_c| nil }
      end.to raise_error(ArgumentError, 'boom')
    end

    # B7: the invoke error events (error / internal_server_exception /
    # model_stream_error_exception) are dispatch failures — raised before any
    # done chunk (the old log-only handlers completed truncated streams).
    it 'raises StreamError before the done chunk on an invoke error event' do
      fake = fake_stream_class.new
      error_event = Struct.new(:error).new(Struct.new(:type, :message).new('api_error', 'service died'))
      text_payload = text_payload_for('Hello')
      client = Object.new
      client.define_singleton_method(:invoke_model_with_response_stream) do |**_request, &block|
        block.call(fake)
        fake.fire(:on_chunk_event, Struct.new(:bytes).new(text_payload))
        fake.fire(:on_error_event, error_event)
      end
      provider.define_singleton_method(:runtime_client) { client }

      chunks = []
      expect do
        provider.send(
          :invoke_model_stream,
          messages: [canonical::Message.build(role: :user, content: 'hi')],
          model: 'anthropic.claude-sonnet-4-20250514-v1:0',
          tools: {}, tool_prefs: nil, thinking: nil,
          params: canonical::Params.build(max_tokens: 100)
        ) { |c| chunks << c }
      end.to raise_error(Legion::Extensions::Llm::Bedrock::StreamError, /service died/)
      expect(chunks.count(&:done?)).to eq(0)
    end

    # B6: a malformed streamed tool-input JSON is a strict parse failure at
    # stream end — raised before the done chunk, never a fabricated {}.
    it 'raises on malformed streamed tool-input JSON before the done chunk' do
      events = [
        { 'type' => 'content_block_start',
          'content_block' => { 'type' => 'tool_use', 'id' => 'tc1', 'name' => 'do_thing' } },
        { 'type' => 'content_block_delta',
          'delta' => { 'type' => 'input_json_delta', 'partial_json' => '{"key": ' } },
        { 'type' => 'content_block_stop' }
      ]
      payload = events.map { |event| Legion::JSON.dump(event) }.join("\n")
      fake = fake_stream_class.new
      client = Object.new
      client.define_singleton_method(:invoke_model_with_response_stream) do |**_request, &block|
        block.call(fake)
        fake.fire(:on_chunk_event, Struct.new(:bytes).new(payload))
      end
      provider.define_singleton_method(:runtime_client) { client }

      chunks = []
      expect do
        provider.send(
          :invoke_model_stream,
          messages: [canonical::Message.build(role: :user, content: 'hi')],
          model: 'anthropic.claude-sonnet-4-20250514-v1:0',
          tools: {}, tool_prefs: nil, thinking: nil,
          params: canonical::Params.build(max_tokens: 100)
        ) { |c| chunks << c }
      end.to raise_error(ArgumentError, /not valid JSON/)
      expect(chunks.count(&:done?)).to eq(0)
    end

    def text_payload_for(text)
      events = [
        { 'type' => 'content_block_start', 'content_block' => { 'type' => 'text' } },
        { 'type' => 'content_block_delta', 'delta' => { 'type' => 'text_delta', 'text' => text } }
      ]
      events.map { |event| Legion::JSON.dump(event) }.join("\n")
    end
  end
end
