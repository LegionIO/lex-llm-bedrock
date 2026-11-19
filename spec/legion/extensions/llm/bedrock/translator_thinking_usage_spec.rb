# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/translator'

RSpec.describe Legion::Extensions::Llm::Bedrock::Translator do
  subject(:translator) { described_class.new(region: 'us-east-1', geo_prefix: 'us') }

  [17, 0, nil].each do |thinking_tokens|
    context "with reported thinking tokens #{thinking_tokens.inspect}" do
      let(:usage) do
        value = { input_tokens: 10, output_tokens: 25, cache_read_input_tokens: 5, cache_creation_input_tokens: 3 }
        value[:output_tokens_details] = { thinking_tokens: thinking_tokens } unless thinking_tokens.nil?
        value
      end

      it 'preserves usage without inventing a thinking block when text is omitted' do
        wire = { content: [{ type: 'text', text: '4.' }], usage: usage, stop_reason: 'end_turn' }
        response = translator.parse_response(Legion::JSON.parse(Legion::JSON.dump(wire), symbolize_names: false),
                                             model: 'test-model')

        expect(response.thinking).to be_nil
        expect(response.usage.thinking_tokens).to eq(thinking_tokens)
        expect(response.usage.input_tokens).to eq(10)
        expect(response.usage.output_tokens).to eq(25)
        expect(response.usage.cache_read_tokens).to eq(5)
        expect(response.usage.cache_write_tokens).to eq(3)
      end

      it 'preserves usage on a normalized done chunk' do
        chunk = translator.parse_chunk({ type: 'done', usage: usage, stop_reason: 'end_turn' })

        expect(chunk.usage.thinking_tokens).to eq(thinking_tokens)
        expect(chunk.usage.output_tokens).to eq(25)
      end

      it 'preserves the final Anthropic event usage and stop reason' do
        chunk = translator.parse_chunk({ type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: usage })

        expect(chunk.usage).not_to be_nil
        expect(chunk.usage.thinking_tokens).to eq(thinking_tokens)
        expect(chunk.usage.output_tokens).to eq(25)
        expect(chunk.stop_reason).to eq(:end_turn)
      end
    end
  end
end
