# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Static model catalog, alias table, context-window facts, and
        # inference-profile prefix list extracted so the primary provider.rb
        # file stays within Metrics/ClassLength.
        class Provider < Legion::Extensions::Llm::Provider
          STATIC_MODELS = [
            { model: 'anthropic.claude-3-haiku-20240307-v1:0', alias: 'claude-3-haiku' },
            { model: 'anthropic.claude-sonnet-4-20250514-v1:0', alias: 'anthropic.claude-sonnet-4' },
            { model: 'anthropic.claude-sonnet-4-20250514-v1:0', alias: 'claude-sonnet-4-6' },
            { model: 'anthropic.claude-sonnet-4-20250514-v1:0', alias: 'claude-sonnet-4-5-20241022' },
            { model: 'anthropic.claude-opus-4-20250515-v1:0', alias: 'claude-opus-4-8' },
            { model: 'anthropic.claude-haiku-4-20250506-v1:0', alias: 'claude-haiku-4-5' },
            { model: 'amazon.titan-text-express-v1', alias: 'titan-text-express' },
            { model: 'amazon.titan-embed-text-v2:0', alias: 'titan-embed-text-v2', usage_type: :embedding },
            { model: 'meta.llama3-2-11b-instruct-v1:0', alias: 'llama-3.2-11b-instruct' },
            { model: 'mistral.mistral-large-3-675b-instruct', alias: 'mistral-large-3' }
          ].freeze

          ALIASES = STATIC_MODELS.to_h { |entry| [entry.fetch(:alias), entry.fetch(:model)] }.freeze

          CONTEXT_WINDOWS = {
            'anthropic.claude-sonnet-4' => 200_000,
            'anthropic.claude-haiku-4' => 200_000,
            'anthropic.claude-opus-4' => 200_000,
            'anthropic.claude-3-5-sonnet' => 200_000,
            'anthropic.claude-3-5-haiku' => 200_000,
            'anthropic.claude-3-haiku' => 200_000,
            'anthropic.claude-3-opus' => 200_000,
            'anthropic.claude-3-sonnet' => 200_000,
            'meta.llama3' => 128_000,
            'meta.llama3-1' => 128_000,
            'meta.llama3-2' => 128_000,
            'meta.llama3-3' => 128_000,
            'mistral.mistral-large' => 128_000,
            'mistral.mistral-small' => 128_000,
            'amazon.titan-text-express' => 8_192,
            'amazon.titan-text-premier' => 32_000,
            'amazon.nova-pro' => 300_000,
            'amazon.nova-lite' => 300_000,
            'amazon.nova-micro' => 128_000
          }.freeze
        end
      end
    end
  end
end
