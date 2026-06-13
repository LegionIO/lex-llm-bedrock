# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/provider'

RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do
  it 'does not expose positional canonical provider arguments' do
    canonical_methods.each { |method_name| expect_keyword_compatible(method_name) }
  end

  describe '#consolidate_adjacent_roles' do
    let(:provider) { described_class.allocate }

    it 'merges consecutive tool-result user messages into one' do
      messages = [
        { role: 'user', content: [{ type: 'text', text: 'hello' }] },
        { role: 'assistant', content: [{ type: 'text', text: 'I will use tools' },
                                       { type: 'tool_use', id: 'tc1', name: 'ruby', input: {} },
                                       { type: 'tool_use', id: 'tc2', name: 'bash', input: {} }] },
        { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tc1', content: [{ type: 'text', text: 'result1' }] }] },
        { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tc2', content: [{ type: 'text', text: 'result2' }] }] }
      ]

      result = provider.send(:consolidate_adjacent_roles, messages)

      expect(result.size).to eq(3)
      expect(result[0][:role]).to eq('user')
      expect(result[1][:role]).to eq('assistant')
      expect(result[2][:role]).to eq('user')
      expect(result[2][:content].size).to eq(2)
      expect(result[2][:content][0][:type]).to eq('tool_result')
      expect(result[2][:content][0][:tool_use_id]).to eq('tc1')
      expect(result[2][:content][1][:type]).to eq('tool_result')
      expect(result[2][:content][1][:tool_use_id]).to eq('tc2')
    end

    it 'preserves messages that already alternate roles' do
      messages = [
        { role: 'user', content: [{ type: 'text', text: 'hi' }] },
        { role: 'assistant', content: [{ type: 'text', text: 'hello' }] },
        { role: 'user', content: [{ type: 'text', text: 'bye' }] }
      ]

      result = provider.send(:consolidate_adjacent_roles, messages)

      expect(result).to eq(messages)
    end

    it 'returns single-message arrays unchanged' do
      messages = [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }]

      result = provider.send(:consolidate_adjacent_roles, messages)

      expect(result).to eq(messages)
    end
  end

  def canonical_methods = %i[chat stream embed image list_models discover_offerings health count_tokens]

  def expect_keyword_compatible(method_name)
    return unless described_class.method_defined?(method_name)

    params = described_class.instance_method(method_name).parameters
    expect(params).not_to include(%i[req messages]), "#{method_name} still has positional messages"
    expect(params).not_to include(%i[req text]), "#{method_name} still has positional text"
    expect(params).not_to include(%i[req prompt]), "#{method_name} still has positional prompt"
  end
end
