# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/translator'

RSpec.describe Legion::Extensions::Llm::Bedrock::Translator do
  subject(:translator) { described_class.new(region: 'us-east-1') }

  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:conformance) { Canonical::Conformance }

  it_behaves_like 'a canonical provider translator', described_class

  describe '#capabilities' do
    it 'declares bedrock provider' do
      expect(translator.capabilities[:provider]).to eq('bedrock')
    end

    it 'declares dual render targets' do
      expect(translator.capabilities[:render_targets]).to eq(%i[converse invoke_model])
    end

    it 'declares thinking support via budget_tokens' do
      expect(translator.capabilities[:thinking]).to eq(:budget_tokens)
    end

    it 'declares stop reason mapping' do
      expect(translator.capabilities[:stop_reasons]['guardrail_intervened']).to eq(:content_filter)
    end

    it 'declares cache_control as false' do
      expect(translator.capabilities[:cache_control]).to be false
    end
  end

  describe '#target_for' do
    it 'selects :converse for non-anthropic model' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hello')])],
        metadata: { model: 'meta.llama3-2-11b-instruct-v1:0' }
      )
      expect(translator.target_for(req)).to eq(:converse)
    end

    it 'selects :invoke_model for anthropic model with thinking' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hello')])],
        thinking: { effort: 'high', budget: 2048 },
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )
      expect(translator.target_for(req)).to eq(:invoke_model)
    end

    it 'selects :invoke_model for anthropic model with tools' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hello')])],
        tools: { search: canonical::ToolDefinition.build(name: 'search', description: 'search') },
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )
      expect(translator.target_for(req)).to eq(:invoke_model)
    end

    it 'selects :converse for anthropic model without thinking and without tools' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hello')])],
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )
      expect(translator.target_for(req)).to eq(:converse)
    end
  end

  describe '#render_request with :converse target' do
    it 'renders messages in converse format' do
      req = canonical::Request.build(
        messages: [
          canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hello')])
        ],
        params: canonical::Params.from_hash({ max_tokens: 2048 }),
        metadata: { model: 'anthropic.claude-3-haiku' }
      )

      wire = translator.render_request(req, target: :converse)

      expect(wire[:model_id]).to match(/\A(anthropic\.claude-3-haiku|us\.anthropic\.claude-3-haiku)/)
      expect(wire[:messages]).to be_a(Array)
      expect(wire[:messages].first[:role]).to eq('user')
      expect(wire[:inference_config][:max_tokens]).to eq(2048)
    end

    it 'renders system prompt as system blocks' do
      req = canonical::Request.build(
        system: 'You are a helpful assistant.',
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        metadata: { model: 'meta.llama3' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire[:system]).to eq([{ text: 'You are a helpful assistant.' }])
    end

    it 'renders tool_config for converse' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('search docs')])],
        tools: {
          search: canonical::ToolDefinition.build(
            name: 'search',
            description: 'Search docs',
            parameters: { type: 'object', properties: {} }
          )
        },
        tool_choice: :auto,
        metadata: { model: 'meta.llama3' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire[:tool_config][:tools].first[:tool_spec][:name]).to eq('search')
    end

    it 'renders inference_config with temperature' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        params: canonical::Params.from_hash({ max_tokens: 1024, temperature: 0.7 }),
        metadata: { model: 'meta.llama3' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire[:inference_config][:temperature]).to eq(0.7)
    end

    it 'renders additional_model_request_fields for thinking' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('think')])],
        thinking: { budget: 2048 },
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )

      # Force converse even for anthropic-thinking to test the field
      wire = translator.render_request(req, target: :converse)
      think = wire[:additional_model_request_fields][:thinking]
      expect(think[:type]).to eq('enabled')
      expect(think[:budget_tokens]).to eq(2048)
    end

    it 'includes stop_sequences at top level' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        params: canonical::Params.from_hash({ stop_sequences: ['[END]'] }),
        metadata: { model: 'meta.llama3' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire[:stop_sequences]).to eq(['[END]'])
    end

    it 'includes seed at top level' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        params: canonical::Params.from_hash({ seed: 42 }),
        metadata: { model: 'meta.llama3' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire[:seed]).to eq(42)
    end

    it 'fails due to :required to Anthropic format' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        tools: { search: canonical::ToolDefinition.build(name: 'search') },
        tool_choice: :required,
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire[:tool_config][:tool_choice]).to eq({ any: {} })
    end

    it 'renders tool_choice as tool name for converse' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        tools: { search: canonical::ToolDefinition.build(name: 'search') },
        tool_choice: :search,
        metadata: { model: 'meta.llama3' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire[:tool_config][:tool_choice]).to eq({ tool: { name: 'search' } })
    end
  end

  describe '#render_request with :invoke_model target' do
    it 'renders in Anthropic Messages format' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )

      wire = translator.render_request(req, target: :invoke_model)
      expect(wire).to have_key(:anthropic_version)
      expect(wire[:messages].first[:role]).to eq('user')
      expect(wire[:messages].first[:content].first[:type]).to eq('text')
    end

    it 'renders tools in Anthropic format' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        tools: { get_weather: canonical::ToolDefinition.build(name: 'get_weather', description: 'Get weather') },
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )

      wire = translator.render_request(req, target: :invoke_model)
      expect(wire[:tools].first[:name]).to eq('get_weather')
    end

    it 'renders thinking config for invoke_model' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        thinking: { budget: 2048 },
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )

      wire = translator.render_request(req, target: :invoke_model)
      expect(wire[:thinking][:type]).to eq('enabled')
      expect(wire[:thinking][:budget_tokens]).to eq(2048)
    end

    it 'renders tool_choice as required in invoke_model' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('hi')])],
        tools: { t: canonical::ToolDefinition.build(name: 't') },
        tool_choice: :required,
        metadata: { model: 'anthropic.claude-sonnet-4' }
      )

      wire = translator.render_request(req, target: :invoke_model)
      expect(wire[:tool_choice]).to eq({ type: 'any' })
    end
  end

  describe '#parse_response' do
    context 'with Converse format response' do
      it 'parses text response' do
        wire = {
          'output' => {
            'message' => {
              'content' => [{ 'text' => 'Hello, world!' }],
              'role' => 'assistant',
              'stop_reason' => 'end_turn'
            }
          },
          'usage' => { 'input_tokens' => 12, 'output_tokens' => 10 }
        }

        resp = translator.parse_response(wire, model: 'test-model')
        expect(resp.text).to eq('Hello, world!')
        expect(resp.stop_reason).to eq(:end_turn)
        expect(resp.model).to eq('test-model')
        expect(resp.usage.input_tokens).to eq(12)
        expect(resp.usage.output_tokens).to eq(10)
      end

      it 'parses tool call response' do
        wire = {
          'output' => {
            'message' => {
              'content' => [
                {
                  'tool_use' => { 'tool_use_id' => 'tc1', 'name' => 'get_weather', 'input' => { 'location' => 'SF' } }
                }
              ],
              'role' => 'assistant',
              'stop_reason' => 'tool_use'
            }
          },
          'usage' => { 'input_tokens' => 100, 'output_tokens' => 50 }
        }

        resp = translator.parse_response(wire, model: 'test-model')
        expect(resp.tool_call?).to be true
        expect(resp.tool_calls.first.id).to eq('tc1')
        expect(resp.tool_calls.first.name).to eq('get_weather')
        expect(resp.tool_calls.first.arguments).to eq({ 'location' => 'SF' })
        expect(resp.stop_reason).to eq(:tool_use)
      end

      it 'parses thinking from content blocks' do
        wire = {
          'output' => {
            'message' => {
              'content' => [
                { 'text' => 'Answer.' },
                { 'reasoning' => { 'text' => 'Let me think...' } }
              ],
              'role' => 'assistant',
              'stop_reason' => 'end_turn'
            }
          },
          'usage' => { 'input_tokens' => 10, 'output_tokens' => 20 }
        }

        resp = translator.parse_response(wire, model: 'test-model')
        expect(resp.thinking).to be_a(canonical::Thinking)
        expect(resp.thinking.content).to eq('Let me think...')
        expect(resp.text).to eq('Answer.')
      end

      it 'maps guardrail_intervened to content_filter' do
        wire = {
          'output' => {
            'message' => {
              'content' => [{ 'text' => 'blocked' }],
              'role' => 'assistant',
              'stop_reason' => 'guardrail_intervened'
            }
          },
          'usage' => { 'input_tokens' => 10, 'output_tokens' => 5 }
        }

        resp = translator.parse_response(wire, model: 'test-model')
        expect(resp.stop_reason).to eq(:content_filter)
      end

      it 'handles empty response' do
        resp = translator.parse_response({}, model: 'test-model')
        expect(resp).to be_a(canonical::Response)
        expect(resp.text).to eq('')
      end

      it 'handles nil response' do
        resp = translator.parse_response(nil, model: 'test-model')
        expect(resp).to be_a(canonical::Response)
        expect(resp.text).to eq('')
      end
    end

    context 'with Anthropic Messages format (invoke_model) response' do
      it 'parses text and thinking' do
        wire = {
          'content' => [
            { 'type' => 'thinking', 'thinking' => 'Let me reason this out.', 'signature' => 'sig123' },
            { 'type' => 'text', 'text' => 'The answer is 42.' }
          ],
          'usage' => { 'input_tokens' => 10, 'output_tokens' => 20, 'thinking_tokens' => 15 },
          'stop_reason' => 'end_turn'
        }

        resp = translator.parse_response(wire, model: 'test-model')
        expect(resp.text).to eq('The answer is 42.')
        expect(resp.thinking).to be_a(canonical::Thinking)
        expect(resp.thinking.content).to eq('Let me reason this out.')
        expect(resp.thinking.signature).to eq('sig123')
        expect(resp.usage.thinking_tokens).to eq(15)
      end

      it 'parses tool calls from Anthropic format' do
        wire = {
          'content' => [
            { 'type' => 'tool_use', 'id' => 'tc1', 'name' => 'get_weather', 'input' => { 'location' => 'SF' } }
          ],
          'usage' => { 'input_tokens' => 45, 'output_tokens' => 28 },
          'stop_reason' => 'tool_use'
        }

        resp = translator.parse_response(wire, model: 'test-model')
        expect(resp.tool_call?).to be true
        expect(resp.tool_calls.first.name).to eq('get_weather')
        expect(resp.stop_reason).to eq(:tool_use)
      end

      it 'parses arguments that are JSON strings' do
        wire = {
          'content' => [
            { 'type' => 'tool_use', 'id' => 'tc1', 'name' => 'do_thing',
              'input' => '{"key": "value"}' }
          ],
          'usage' => { 'input_tokens' => 10, 'output_tokens' => 5 },
          'stop_reason' => 'tool_use'
        }

        resp = translator.parse_response(wire, model: 'test-model')
        expect(resp.tool_calls.first.arguments).to be_a(Hash)
        # Legion::JSON.load returns symbol keys
        expect(resp.tool_calls.first.arguments[:key]).to eq('value')
      end
    end
  end

  describe '#parse_chunk' do
    context 'with canonical text_delta' do
      it 'parses text delta' do
        chunk = { 'type' => 'text_delta', 'delta' => { 'text' => 'Hello' }, 'request_id' => 'req1' }
        result = translator.parse_chunk(chunk)

        expect(result).to be_a(canonical::Chunk)
        expect(result.type).to eq(:text_delta)
        expect(result.delta).to eq('Hello')
      end

      it 'returns nil for empty delta' do
        chunk = { 'type' => 'text_delta', 'delta' => { 'text' => '' }, 'request_id' => 'req1' }
        expect(translator.parse_chunk(chunk)).to be_nil
      end
    end

    context 'with canonical thinking_delta' do
      it 'parses thinking delta without signature' do
        chunk = { 'type' => 'thinking_delta', 'delta' => { 'thinking' => 'Let me...' }, 'request_id' => 'req1' }
        result = translator.parse_chunk(chunk)

        expect(result.type).to eq(:thinking_delta)
        expect(result.delta).to eq('Let me...')
      end

      it 'preserves signature on thinking delta' do
        chunk = { 'type' => 'thinking_delta', 'delta' => { 'thinking' => 'done' },
                  'signature' => 'sig1', 'request_id' => 'req1' }
        result = translator.parse_chunk(chunk)

        expect(result.signature).to eq('sig1')
      end
    end

    context 'with canonical tool_call_delta' do
      it 'parses tool call delta' do
        chunk = {
          'type' => 'tool_call_delta',
          'tool_call' => { 'id' => 'tc1', 'name' => 'search', 'arguments' => { 'query' => 'test' } },
          'request_id' => 'req1'
        }
        result = translator.parse_chunk(chunk)

        expect(result.type).to eq(:tool_call_delta)
        expect(result.tool_call&.name).to eq('search')
      end

      it 'returns nil when no tool_call present' do
        chunk = { 'type' => 'tool_call_delta', 'request_id' => 'req1' }
        expect(translator.parse_chunk(chunk)).to be_nil
      end
    end

    context 'with canonical done chunk' do
      it 'parses done with usage and stop_reason' do
        chunk = {
          'type' => 'done',
          'stop_reason' => 'end_turn',
          'usage' => { 'input_tokens' => 12, 'output_tokens' => 10 },
          'request_id' => 'req1'
        }
        result = translator.parse_chunk(chunk)

        expect(result.type).to eq(:done)
        expect(result.stop_reason).to eq(:end_turn)
        expect(result.usage&.input_tokens).to eq(12)
      end
    end

    context 'with canonical error chunk' do
      it 'parses error with metadata' do
        chunk = {
          'type' => 'error',
          'metadata' => { 'error' => { 'type' => 'overloaded', 'message' => 'Timeout' } },
          'request_id' => 'req1'
        }
        result = translator.parse_chunk(chunk)

        expect(result.type).to eq(:error)
        expect(result.error?).to be true
      end
    end

    context 'with Anthropic event types' do
      it 'parses text_delta from Anthropic event' do
        chunk = { 'type' => 'text_delta', 'delta' => { 'text' => 'Hello' }, 'request_id' => 'req1' }
        # This will be matched by parse_text_delta first, not parse_anthropic_event
        result = translator.parse_chunk(chunk)
        expect(result&.type).to eq(:text_delta)
        expect(result&.delta).to eq('Hello')
      end
    end

    context 'with nil input' do
      it 'returns nil for nil' do
        expect(translator.parse_chunk(nil)).to be_nil
      end

      it 'returns nil for empty hash' do
        expect(translator.parse_chunk({})).to be_nil
      end
    end
  end

  describe 'round-trip rendering' do
    it 'renders and parses simple text back out' do
      req = canonical::Request.build(
        messages: [canonical::Message.build(role: :user,
                                            content: [canonical::ContentBlock.text('Hello, how are you?')])],
        params: canonical::Params.from_hash({ max_tokens: 1024 }),
        metadata: { model: 'anthropic.claude-3-haiku' }
      )

      wire = translator.render_request(req, target: :converse)
      expect(wire).to be_a(Hash)
      expect(wire.keys & %i[model_id messages]).to include(:model_id) || include(:messages)

      # Simulate a response
      response_wire = {
        'output' => {
          'message' => {
            'content' => [{ 'text' => "I'm doing well, thank you for asking!" }],
            'role' => 'assistant',
            'stop_reason' => 'end_turn'
          }
        },
        'usage' => { 'input_tokens' => 12, 'output_tokens' => 10 }
      }

      resp = translator.parse_response(response_wire, model: 'anthropic.claude-3-haiku')
      expect(resp).to be_a(canonical::Response)
      expect(resp.text).to eq("I'm doing well, thank you for asking!")
      expect(resp.stop_reason).to eq(:end_turn)
    end
  end
end
