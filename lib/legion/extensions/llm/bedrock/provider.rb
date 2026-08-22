# frozen_string_literal: true

require 'base64'
require 'aws-sdk-bedrock'
require 'aws-sdk-bedrockruntime'
require 'legion/json'
require 'legion/logging/helper'
require 'legion/extensions/llm'
require 'legion/extensions/llm/bedrock/thinking_modes'
require 'legion/extensions/llm/bedrock/render_defaults'
require 'legion/extensions/llm/bedrock/provider/constants'
require 'legion/extensions/llm/bedrock/provider/class_methods'
require 'legion/extensions/llm/bedrock/provider/client_helpers'
require 'legion/extensions/llm/bedrock/provider/model_catalog_helpers'
require 'legion/extensions/llm/bedrock/provider/converse_helpers'
require 'legion/extensions/llm/bedrock/provider/invoke_model_helpers'
require 'legion/extensions/llm/bedrock/provider/dispatch_helpers'

module Legion
  module Extensions
    module Llm
      module Bedrock
        class StaticCredentialsBlockedError < Legion::Extensions::Llm::ConfigurationError; end

        # B7: an explicit provider stream-error event (converse ErrorEvent,
        # invoke error/internal_server_exception/model_stream_error) is a
        # dispatch failure — raised before any done chunk so a truncated
        # stream is never presented as a completed response.
        class StreamError < Legion::Extensions::Llm::Error; end

        # Amazon Bedrock provider implementation for the Legion::Extensions::Llm contract.
        #
        # All private helpers are extracted into dedicated modules under provider/:
        #   ClassMethods     — class-level slug, caps, resolve_model_id, inference_profile_id
        #   ClientHelpers    — AWS SDK client construction, credentials, low-level parsing
        #   ModelCatalogHelpers — health/readiness, fetch_model_detail
        #   ConverseHelpers  — Converse API request formatting, response parsing, streaming
        #   InvokeModelHelpers — invoke_model path for Anthropic thinking/tools
        #   DispatchHelpers  — public chat/stream/count_tokens/embed/complete
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Logging::Helper

          extend ClassMethods
          include ClientHelpers
          include ModelCatalogHelpers
          include ConverseHelpers
          include InvokeModelHelpers
          include DispatchHelpers

          # Capability predicates inferred from Bedrock model IDs and API modalities.
          module Capabilities
            module_function

            def chat?(model) = !embeddings?(model)
            def streaming?(model) = chat?(model)
            def vision?(model) = model_id(model).match?(/(claude-3|llama3-2-(11|90)b)/)
            def functions?(model) = chat?(model)
            def embeddings?(model) = model_id(model).match?(/embed|embedding/)

            def model_id(model)
              return model.fetch('model', model.fetch('id', '')) if model.is_a?(Hash)

              model.respond_to?(:id) ? model.id.to_s : model.to_s
            end
          end

          def translator
            @translator ||= Translator.new(region: region)
          end

          def settings
            Bedrock.default_settings
          end

          def api_base
            config.bedrock_endpoint || "https://bedrock-runtime.#{region}.amazonaws.com"
          end

          def completion_url  = 'Converse'
          def stream_url      = 'ConverseStream'
          def models_url      = 'ListFoundationModels'
          def embedding_url(**) = 'InvokeModel'
          def count_tokens_url = 'CountTokens'

          def region
            config.bedrock_region || settings[:region] || 'us-east-1'
          end

          def geo_prefix
            configured = config.bedrock_geo_prefix if config.respond_to?(:bedrock_geo_prefix)
            self.class.normalize_geo_prefix(configured || settings[:geo_prefix])
          end
        end
      end
    end
  end
end
