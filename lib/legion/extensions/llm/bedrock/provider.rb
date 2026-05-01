# frozen_string_literal: true

require 'aws-sdk-bedrock'
require 'aws-sdk-bedrockruntime'
require 'legion/json'
require 'legion/logging'
require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Amazon Bedrock provider implementation for the Legion::Extensions::Llm contract.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
          include Legion::Logging::Helper if defined?(Legion::Logging::Helper)

          DEFAULT_REGION = 'us-east-1'

          STATIC_MODELS = [
            { model: 'anthropic.claude-3-haiku-20240307-v1:0', alias: 'claude-3-haiku' },
            { model: 'amazon.titan-text-express-v1', alias: 'titan-text-express' },
            { model: 'amazon.titan-embed-text-v2:0', alias: 'titan-embed-text-v2', usage_type: :embedding },
            { model: 'meta.llama3-2-11b-instruct-v1:0', alias: 'llama-3.2-11b-instruct' },
            { model: 'mistral.mistral-large-3-675b-instruct', alias: 'mistral-large-3' }
          ].freeze

          ALIASES = STATIC_MODELS.to_h { |entry| [entry.fetch(:alias), entry.fetch(:model)] }.freeze

          class << self
            attr_writer :registry_publisher

            def slug = 'bedrock'

            def configuration_options
              %i[
                bedrock_region
                bedrock_endpoint
                bedrock_access_key_id
                bedrock_secret_access_key
                bedrock_session_token
                bedrock_profile
                bedrock_stub_responses
              ]
            end

            def configuration_requirements = []
            def capabilities = Capabilities

            def registry_publisher
              @registry_publisher ||= RegistryPublisher.new
            end

            def resolve_model_id(model_id, config: nil) # rubocop:disable Lint/UnusedMethodArgument
              ALIASES.fetch(model_id.to_s, model_id.to_s)
            end
          end

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

          def api_base
            config.bedrock_endpoint || "https://bedrock-runtime.#{region}.amazonaws.com"
          end

          def completion_url = 'Converse'
          def stream_url = 'ConverseStream'
          def models_url = 'ListFoundationModels'
          def embedding_url(**) = 'InvokeModel'
          def count_tokens_url = 'CountTokens'

          def region
            config.bedrock_region || DEFAULT_REGION
          end

          def discover_offerings(live: false, **filters)
            unless live
              log.debug { 'bedrock.provider.discover_offerings: returning static catalog' }
              return static_offerings(**filters)
            end

            log.info { "bedrock.provider.discover_offerings: listing foundation models (region=#{region})" }
            response = bedrock_client.list_foundation_models(**filters)
            Array(value(response, :model_summaries)).map { |summary| offering_from_summary(summary) }.tap do |offerings|
              log.info { "bedrock.provider.discover_offerings: found #{offerings.size} models" }
              self.class.registry_publisher.publish_offerings_async(offerings, readiness: readiness(live: false))
            end
          end

          def offering_for(model:, model_family: nil, instance_id: :default, **metadata)
            model_id = self.class.resolve_model_id(model)
            build_offering(
              model: model_id,
              alias_name: alias_for(model_id),
              model_family: model_family || model_family_for(model_id),
              instance_id: instance_id,
              usage_type: metadata.delete(:usage_type) || usage_type_for(model_id),
              metadata: metadata
            )
          end

          def health(live: false)
            baseline = {
              provider: :bedrock,
              region: region,
              configured: true,
              ready: true,
              live: live,
              credentials: credential_source
            }
            unless live
              log.debug { "bedrock.provider.health: offline check (region=#{region})" }
              return baseline.merge(checked: false)
            end

            log.info { "bedrock.provider.health: live check (region=#{region})" }
            bedrock_client.list_foundation_models
            log.info { 'bedrock.provider.health: live check passed' }
            baseline.merge(checked: true)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'bedrock.provider.health')
            baseline.merge(checked: true, ready: false, error: e.class.name, message: e.message)
          end

          def readiness(live: false)
            log.debug { "bedrock.provider.readiness: checking (live=#{live})" }
            health(live: live).merge(local: false, remote: true, api_base: api_base,
                                     endpoints: endpoint_manifest).tap do |metadata|
              self.class.registry_publisher.publish_readiness_async(metadata) if live
            end
          end

          def list_models
            log.info { 'bedrock.provider.list_models: fetching live model list' }
            discover_offerings(live: true).map do |offering|
              Legion::Extensions::Llm::Model::Info.new(
                id: offering.model,
                name: offering.metadata[:alias] || offering.model,
                provider: :bedrock,
                family: offering.metadata[:model_family],
                capabilities: offering.capabilities.map(&:to_s),
                metadata: offering.to_h
              )
            end
          end

          def chat(messages, model:, temperature: nil, max_tokens: nil, tools: {}, tool_prefs: nil, params: {})
            log.info { "bedrock.provider.chat: model=#{model_id(model)} messages=#{messages.size}" }
            request = Utils.deep_merge(
              converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:),
              params
            )
            parse_converse_response(runtime_client.converse(**request), model_id(model))
          end

          def stream(messages, model:, temperature: nil, max_tokens: nil, tools: {}, tool_prefs: nil, params: {},
                     &)
            log.info { "bedrock.provider.stream: model=#{model_id(model)} messages=#{messages.size}" }
            request = Utils.deep_merge(
              converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:),
              params
            )
            stream_converse(request, model_id(model), &)
          end

          def count_tokens(messages, model:, system: nil, params: {})
            log.debug { "bedrock.provider.count_tokens: model=#{model_id(model)}" }
            request = Utils.deep_merge(
              {
                model_id: model_id(model),
                input: { converse: { messages: format_messages(messages), system: system_blocks(system) }.compact }
              },
              params
            )
            response = runtime_client.count_tokens(**request)
            { input_tokens: value(response, :input_tokens), raw: normalize_response(response) }
          end

          def embed(text, model:, dimensions: nil)
            mid = model_id(model)
            unless titan_embed?(mid)
              raise NotImplementedError,
                    "Bedrock embedding payload for #{mid} is not standardized"
            end

            log.info { "bedrock.provider.embed: model=#{mid}" }
            body = { inputText: text, dimensions: dimensions }.compact
            response = runtime_client.invoke_model(
              model_id: mid,
              content_type: 'application/json',
              accept: 'application/json',
              body: Legion::JSON.generate(body)
            )
            parse_embedding_response(response, model: mid)
          end

          def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, # rubocop:disable Lint/UnusedMethodArgument
                       tool_prefs: nil, &)
            payload = params.dup
            payload[:additional_model_request_fields] ||= {}
            payload[:additional_model_request_fields][:thinking] = thinking if thinking
            payload[:additional_model_request_fields][:response_format] = schema if schema

            if block_given?
              stream(messages, model:, temperature:, tools:, tool_prefs:, params: payload, &)
            else
              chat(messages, model:, temperature:, tools:, tool_prefs:, params: payload)
            end
          end

          private

          def static_offerings(**filters)
            STATIC_MODELS.filter_map do |entry|
              provider_filter = normalize_provider(filters[:by_provider])
              next if provider_filter && model_family_for(entry.fetch(:model)) != provider_filter

              offering_for(**entry.slice(:model, :usage_type))
            end
          end

          def offering_from_summary(summary)
            model = value(summary, :model_id)
            build_offering(
              model: model,
              alias_name: alias_for(model),
              model_family: normalize_provider(value(summary, :provider_name)) || model_family_for(model),
              usage_type: usage_type_from_modalities(value(summary, :output_modalities)),
              capabilities: capabilities_from_summary(summary),
              metadata: normalize_response(summary)
            )
          end

          def build_offering(model:, model_family:, usage_type:, instance_id: :default, alias_name: nil,
                             capabilities: nil, metadata: {})
            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :bedrock,
              instance_id: instance_id,
              transport: :aws_sdk,
              tier: :frontier,
              model: model,
              usage_type: usage_type,
              capabilities: capabilities || default_capabilities(model),
              metadata: metadata.merge(model_family: model_family, alias: alias_name).compact
            )
          end

          def converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:)
            {
              model_id: model_id(model),
              messages: format_messages(messages.reject { |message| message.role == :system }),
              system: format_system(messages),
              inference_config: { temperature: temperature, max_tokens: max_tokens || model_max_tokens(model) }.compact,
              tool_config: format_tool_config(tools, tool_prefs)
            }.compact
          end

          def format_messages(messages)
            messages.map do |message|
              {
                role: bedrock_role(message.role),
                content: content_blocks(message.content)
              }
            end
          end

          def format_system(messages)
            system_messages = messages.select { |message| message.role == :system }
            system_text = system_messages.map { |message| content_text(message.content) }
            system_blocks(system_text.join("\n"))
          end

          def system_blocks(system)
            return nil if system.to_s.empty?

            [{ text: system }]
          end

          def bedrock_role(role)
            role == :assistant ? 'assistant' : 'user'
          end

          def content_blocks(content)
            raw_content(content) || [{ text: content_text(content) }]
          end

          def raw_content(content)
            return nil unless content.is_a?(Legion::Extensions::Llm::Content::Raw)

            Array(content.format)
          end

          def content_text(content)
            return content.text.to_s if content.respond_to?(:text)

            content.to_s
          end

          def format_tool_config(tools, tool_prefs)
            return nil if tools.empty?

            { tools: tools.values.map { |tool| tool_definition(tool) }, tool_choice: tool_choice(tool_prefs) }.compact
          end

          def tool_definition(tool)
            {
              tool_spec: {
                name: tool.name,
                description: tool.description,
                input_schema: { json: tool_schema(tool) }
              }
            }
          end

          def tool_schema(tool)
            return tool.params_schema if tool.respond_to?(:params_schema) && tool.params_schema

            { type: 'object', properties: {} }
          end

          def tool_choice(tool_prefs)
            return nil unless tool_prefs

            choice = tool_prefs[:choice] || tool_prefs['choice']
            case choice
            when :auto, 'auto'
              { auto: {} }
            when :required, 'required'
              { any: {} }
            else
              { tool: { name: choice.to_s } }
            end
          end

          def parse_converse_response(response, fallback_model)
            output = value(response, :output)
            message = value(output, :message)
            usage = value(response, :usage) || {}

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: text_from(value(message, :content)),
              model_id: fallback_model,
              tool_calls: parse_tool_calls(value(message, :content)),
              input_tokens: value(usage, :input_tokens),
              output_tokens: value(usage, :output_tokens),
              raw: normalize_response(response)
            )
          end

          def stream_converse(request, fallback_model)
            accumulated = +''
            final_usage = nil

            runtime_client.converse_stream(**request) do |stream|
              stream.on_content_block_delta_event do |event|
                text = value(value(event, :delta), :text)
                next if text.nil?

                accumulated << text
                if block_given?
                  yield Legion::Extensions::Llm::Chunk.new(role: :assistant, content: text,
                                                           model_id: fallback_model)
                end
              end
              stream.on_metadata_event { |event| final_usage = value(event, :usage) }
            end

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: accumulated,
              model_id: fallback_model,
              input_tokens: value(final_usage, :input_tokens),
              output_tokens: value(final_usage, :output_tokens)
            )
          end

          def parse_embedding_response(response, model:)
            body = parse_body(value(response, :body))
            vectors = body['embedding'] || body['embeddings'] || body.dig('data', 0, 'embedding')
            Legion::Extensions::Llm::Embedding.new(vectors: vectors, model: model,
                                                   input_tokens: body['inputTextTokenCount'])
          end

          def text_from(content)
            Array(content).filter_map { |block| value(block, :text) }.join
          end

          def parse_tool_calls(content)
            calls = Array(content).filter_map { |block| value(block, :tool_use) }
            return nil if calls.empty?

            calls.to_h do |call|
              name = value(call, :name)
              [
                value(call, :tool_use_id) || name,
                Legion::Extensions::Llm::ToolCall.new(id: value(call, :tool_use_id) || name, name: name,
                                                      arguments: value(call, :input) || {})
              ]
            end
          end

          def bedrock_client
            Aws::Bedrock::Client.new(client_options)
          end

          def runtime_client
            Aws::BedrockRuntime::Client.new(client_options)
          end

          def client_options
            {
              region: region,
              endpoint: config.bedrock_endpoint,
              credentials: credentials,
              stub_responses: config.bedrock_stub_responses
            }.compact
          end

          def credentials
            return Aws::SharedCredentials.new(profile_name: config.bedrock_profile) if config.bedrock_profile
            return nil unless config.bedrock_access_key_id

            Aws::Credentials.new(config.bedrock_access_key_id, config.bedrock_secret_access_key,
                                 config.bedrock_session_token)
          end

          def credential_source
            return :static if config.bedrock_access_key_id
            return :profile if config.bedrock_profile

            :aws_sdk_default_chain
          end

          def model_id(model)
            id = model.respond_to?(:id) ? model.id : model
            self.class.resolve_model_id(id)
          end

          def model_max_tokens(model)
            model.respond_to?(:max_tokens) ? model.max_tokens : nil
          end

          def usage_type_for(model)
            titan_embed?(model) ? :embedding : :inference
          end

          def usage_type_from_modalities(output_modalities)
            Array(output_modalities).map(&:to_s).include?('EMBEDDING') ? :embedding : :inference
          end

          def default_capabilities(model)
            return %i[embedding] if titan_embed?(model)

            capabilities = %i[chat streaming]
            capabilities << :vision if Capabilities.vision?(model)
            capabilities << :functions if Capabilities.functions?(model)
            capabilities
          end

          def capabilities_from_summary(summary)
            capabilities = []
            capabilities << :embedding if usage_type_from_modalities(value(summary, :output_modalities)) == :embedding
            capabilities << :chat if capabilities.empty?
            capabilities << :streaming if value(summary, :response_streaming_supported)
            capabilities << :vision if Array(value(summary, :input_modalities)).map(&:to_s).include?('IMAGE')
            capabilities
          end

          def model_family_for(model)
            normalize_provider(model.to_s.split('.').first)
          end

          def normalize_provider(provider)
            value = provider.to_s.downcase.tr(' ', '_').tr('-', '_')
            return nil if value.empty?

            case value
            when 'mistral_ai'
              :mistral
            else
              value.to_sym
            end
          end

          def titan_embed?(model)
            model.to_s.include?('titan-embed')
          end

          def alias_for(model)
            ALIASES.key(model)
          end

          def parse_body(body)
            body = body.read if body.respond_to?(:read)
            body = body.string if body.respond_to?(:string)
            body.is_a?(String) ? Legion::JSON.parse(body, symbolize_names: false) : body.to_h
          end

          def normalize_response(response)
            response.respond_to?(:to_h) ? response.to_h : {}
          end

          def value(object, key)
            return nil if object.nil?

            string_key = key.to_s
            return object[key] if object.respond_to?(:key?) && object.key?(key)
            return object[string_key] if object.respond_to?(:key?) && object.key?(string_key)
            return object.public_send(key) if object.respond_to?(key)

            if object.respond_to?(:to_h)
              hash = object.to_h
              return hash[key] if hash.key?(key)
              return hash[string_key] if hash.key?(string_key)
            end

            nil
          end
        end
      end
    end
  end
end
