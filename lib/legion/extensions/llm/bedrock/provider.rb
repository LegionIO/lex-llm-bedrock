# frozen_string_literal: true

require 'base64'
require 'aws-sdk-bedrock'
require 'aws-sdk-bedrockruntime'
require 'legion/json'
require 'legion/logging/helper'
require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Amazon Bedrock provider implementation for the Legion::Extensions::Llm contract.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
          include Legion::Logging::Helper

          STATIC_MODELS = [
            { model: 'anthropic.claude-3-haiku-20240307-v1:0', alias: 'claude-3-haiku' },
            { model: 'anthropic.claude-sonnet-4-20250514-v1:0', alias: 'anthropic.claude-sonnet-4' },
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

          class << self
            def slug = 'bedrock'
            def default_transport = :aws_sdk
            def default_tier = :cloud

            def configuration_options
              %i[
                bedrock_region
                bedrock_endpoint
                bedrock_access_key_id
                bedrock_secret_access_key
                bedrock_session_token
                bedrock_profile
                bedrock_stub_responses
                bearer_token
              ]
            end

            def configuration_requirements = []
            def capabilities = Capabilities

            def registry_publisher
              Bedrock.registry_publisher
            end

            def resolve_model_id(model_id, config: nil) # rubocop:disable Lint/UnusedMethodArgument
              ALIASES.fetch(model_id.to_s, model_id.to_s)
            end

            INFERENCE_PROFILE_PREFIXES = %w[anthropic. meta. mistral. cohere. ai21.].freeze

            def inference_profile_id(model, region: nil)
              return model if model.start_with?('us.', 'eu.', 'ap.', 'arn:')
              return model unless INFERENCE_PROFILE_PREFIXES.any? { |p| model.start_with?(p) }

              prefix = region ? region_prefix(region) : 'us'
              "#{prefix}.#{model}"
            end

            # Region-based inference profile prefix mapping.
            # Bare model IDs (e.g. anthropic.claude-sonnet-4) get the region prefix.
            REGION_PREFIX = {
              'us-east-1' => 'us', 'us-east-2' => 'us', 'us-west-1' => 'us', 'us-west-2' => 'us',
              'eu-central-1' => 'eu', 'eu-west-1' => 'eu', 'eu-west-2' => 'eu', 'eu-west-3' => 'eu',
              'ap-south-1' => 'ap', 'ap-southeast-1' => 'ap', 'ap-southeast-2' => 'ap', 'ap-northeast-1' => 'ap'
            }.freeze

            def region_prefix(region)
              REGION_PREFIX.fetch(region.to_s, 'us')
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
            config.bedrock_region || settings[:region] || 'us-east-1'
          end

          def discover_offerings(live: false, **filters)
            unless live
              return @cached_offerings if @cached_offerings&.any?

              log.debug { 'bedrock.provider.discover_offerings: returning static catalog' }
              return static_offerings(**filters)
            end

            log.info { "bedrock.provider.discover_offerings: listing foundation models (region=#{region})" }
            response = bedrock_client.list_foundation_models(**filters)
            @cached_offerings = Array(value(response, :model_summaries)).filter_map do |summary|
              offering = offering_from_summary(summary)
              model_id = offering.respond_to?(:model) ? offering.model : (offering[:model] || offering[:id])
              next unless model_allowed?(model_id.to_s)

              offering
            end
            log.info { "bedrock.provider.discover_offerings: found #{@cached_offerings.size} models" }
            @cached_offerings
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

          def list_models(**)
            log.info { 'bedrock.provider.list_models: fetching live model list' }
            response = bedrock_client.list_foundation_models
            models = Array(value(response, :model_summaries)).filter_map { |summary| model_info_from_summary(summary) }
            log.info { "bedrock.provider.list_models: found #{models.size} models" }
            self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            models
          end

          def chat(
            messages:,
            model:,
            temperature: nil,
            max_tokens: nil,
            tools: {},
            tool_prefs: nil,
            params: {},
            thinking: nil,
            **_provider_options
          )
            log.info { "bedrock.provider.chat: model=#{model_id(model)} messages=#{messages.size}" }

            # Bedrock Converse API silently drops thinking config and tool_use blocks
            # for Claude Sonnet 4+. Use invoke_model with native Anthropic payload.
            if anthropic_model?(model_id(model)) && (thinking || (tools && !tools.empty?))
              return invoke_model_chat(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                       thinking:, params:)
            end

            request = Utils.deep_merge(
              converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:, thinking:),
              params
            )
            log.debug do
              "bedrock.provider.chat: request prepared model=#{model_id(model)} tools=#{tools.size} " \
                "tool_choice=#{tool_choice_label(tool_prefs)} param_keys=#{params.keys.map(&:to_s).sort.join(',')}"
            end

            # Log the thinking config being sent
            thinking_config = request.dig(:additional_model_request_fields, :thinking)
            log.debug { "bedrock.provider.chat: thinking_config=#{thinking_config.inspect}" } if thinking_config

            start_time = Time.now
            response = begin
              runtime_client.converse(**request)
            rescue StandardError => e
              elapsed = ((Time.now - start_time) * 1000).round
              log.error do
                "bedrock.provider.chat: converse failed model=#{model_id(model)} " \
                  "error=#{e.class}: #{e.message} elapsed_ms=#{elapsed}"
              end
              raise
            end
            elapsed = ((Time.now - start_time) * 1000).round

            # Dump raw Bedrock response for debugging
            raw_debug = response.respond_to?(:to_h) ? response.to_h : response.inspect[0, 2000]
            dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)
            if dump_path
              begin
                dump_file = File.join(dump_path, "bedrock_chat_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
                File.write(dump_file, Legion::JSON.pretty_generate(raw_debug))
                log.debug { "bedrock.provider.chat: raw response dumped to #{dump_file}" }
              rescue StandardError => e
                log.warn { "bedrock.provider.chat: failed to dump raw response: #{e.message}" }
              end
            end

            # Log response metadata
            usage = value(response, :usage) || {}
            additional_fields = value(response, :additional_model_response_fields)
            output = value(response, :output)
            content_blocks = output ? value(output, :message) : nil
            # AWS SDK content blocks are structs, not hashes — use safe inspection
            block_types = if content_blocks
                            Array(value(content_blocks, :content)).map do |b|
                              if b.respond_to?(:reasoning)
                                'reasoning'
                              elsif b.respond_to?(:text)
                                'text'
                              elsif b.respond_to?(:tool_use)
                                'tool_use'
                              else
                                b.class.name
                              end
                            end.inspect
                          else
                            'none'
                          end
            af_keys = if additional_fields.respond_to?(:to_h)
                        additional_fields.to_h.keys.map(&:to_s).sort
                      else
                        additional_fields.respond_to?(:keys) ? additional_fields.keys.map(&:to_s).sort : []
                      end

            log.debug do
              "bedrock.provider.chat: response received model=#{model_id(model)} elapsed_ms=#{elapsed} " \
                "usage=#{usage.inspect} additional_fields_keys=#{af_keys.inspect} " \
                "content_block_types=#{block_types}"
            end

            parse_converse_response(response, model_id(model))
          end

          def stream(messages:, model:, temperature: nil, max_tokens: nil, tools: {}, tool_prefs: nil, params: {},
                     thinking: nil, **_provider_options, &)
            log.info do
              "bedrock.provider.stream: model=#{model_id(model)} messages=#{messages.size} tools=#{tools.size}"
            end

            # Bedrock Converse API silently drops thinking config and tool_use blocks
            # for Claude Sonnet 4+. Use invoke_model with native Anthropic payload.
            if anthropic_model?(model_id(model)) && (thinking || (tools && !tools.empty?))
              return invoke_model_stream(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                         thinking:, params:, &)
            end

            request = Utils.deep_merge(
              converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:, thinking:),
              params
            )
            log.debug do
              "bedrock.provider.stream: request prepared model=#{model_id(model)} tools=#{tools.size} " \
                "tool_choice=#{tool_choice_label(tool_prefs)} param_keys=#{params.keys.map(&:to_s).sort.join(',')}"
            end

            # Log the thinking config being sent
            thinking_config = request.dig(:additional_model_request_fields, :thinking)
            log.debug { "bedrock.provider.stream: thinking_config=#{thinking_config.inspect}" } if thinking_config

            start_time = Time.now
            result = stream_converse(request, model_id(model), &)
            elapsed = ((Time.now - start_time) * 1000).round
            log.debug { "bedrock.provider.stream: completed model=#{model_id(model)} elapsed_ms=#{elapsed}" }
            result
          end

          def count_tokens(
            messages:,
            model:,
            system: nil,
            params: {}
          )
            log.debug { "bedrock.provider.count_tokens: model=#{model_id(model)}" }
            request = Utils.deep_merge(
              {
                model_id: self.class.inference_profile_id(model_id(model), region: region),
                input: { converse: { messages: format_messages(messages), system: system_blocks(system) }.compact }
              },
              params
            )
            response = runtime_client.count_tokens(**request)
            { input_tokens: value(response, :input_tokens), raw: normalize_response(response) }
          end

          def embed(
            text:,
            model:,
            dimensions: nil,
            params: {},
            **_provider_options
          )
            mid = model_id(model)
            unless titan_embed?(mid)
              raise NotImplementedError,
                    "Bedrock embedding payload for #{mid} is not standardized"
            end

            log.info { "bedrock.provider.embed: model=#{mid}" }
            body = Utils.deep_merge({ inputText: text, dimensions: dimensions }.compact, params)
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
            payload[:additional_model_request_fields][:response_format] = schema if schema

            if block_given?
              stream(messages:, model:, temperature:, tools:, tool_prefs:, params: payload, thinking:, &)
            else
              chat(messages:, model:, temperature:, tools:, tool_prefs:, params: payload, thinking:)
            end
          end

          private

          # Returns true if the model is an Anthropic model on Bedrock
          def anthropic_model?(model_id)
            return false unless model_id

            mid = model_id.to_s
            mid.start_with?('anthropic.', 'us.anthropic.', 'eu.anthropic.', 'ap.anthropic.')
          end

          # --- invoke_model path for thinking-enabled Anthropic models ---
          # Bedrock Converse API silently drops thinking config for Claude Sonnet 4+.
          # invoke_model uses the native Anthropic Messages API payload format which supports thinking.

          def invoke_model_chat(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                thinking:, _params: nil, **_rest)
            mid = model_id(model)
            body = build_invoke_model_body(
              messages: messages, model: mid, temperature: temperature, max_tokens: max_tokens,
              tools: tools, tool_prefs: tool_prefs, thinking: thinking
            )

            log.debug { "bedrock.provider.invoke_model_chat: model=#{mid} thinking=#{thinking.inspect}" }

            response = runtime_client.invoke_model(
              model_id: self.class.inference_profile_id(mid, region: region),
              content_type: 'application/json',
              accept: 'application/json',
              body: Legion::JSON.generate(body)
            )

            # Read body once — it's a stream that can only be consumed once
            body_raw = value(response, :body)
            body_raw = body_raw.read if body_raw.respond_to?(:read)
            body_raw = body_raw.string if body_raw.respond_to?(:string)
            body_str = body_raw.to_s

            # Dump raw invoke_model response for debugging
            dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)
            if dump_path
              begin
                dump_file = File.join(dump_path, "bedrock_invoke_chat_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
                File.write(dump_file, body_str)
                log.debug { "bedrock.provider.invoke_model_chat: raw response dumped to #{dump_file}" }
              rescue StandardError => e
                log.warn { "bedrock.provider.invoke_model_chat: failed to dump raw response: #{e.message}" }
              end
            end

            # Wrap body string back into response so parse_invoke_model_response can use it
            parsed_body = Legion::JSON.parse(body_str, symbolize_names: false)
            parse_invoke_model_response_hash(parsed_body, mid)
          end

          def invoke_model_stream(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:,
                                  thinking:, _params: nil, **_rest, &)
            mid = model_id(model)
            body = build_invoke_model_body(
              messages: messages, model: mid, temperature: temperature, max_tokens: max_tokens,
              tools: tools, tool_prefs: tool_prefs, thinking: thinking, streaming: true
            )

            log.debug { "bedrock.provider.invoke_model_stream: model=#{mid} thinking=#{thinking.inspect}" }

            state = {
              accumulated: +'',
              thinking: +'',
              final_usage: nil,
              stop_reason: nil,
              tool_use_blocks: [],
              current_tool_use: nil,
              in_thinking: false,
              raw_events: []
            }

            dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)

            # rubocop:disable Metrics/BlockLength
            runtime_client.invoke_model_with_response_stream(
              model_id: self.class.inference_profile_id(mid, region: region),
              content_type: 'application/json',
              accept: 'application/json',
              body: Legion::JSON.generate(body)
            ) do |stream|
              # ResponseStream is an event emitter (Aws::BedrockRuntime::EventStreams::ResponseStream).
              # Wire on_chunk_event to receive actual data events.
              # Each chunk contains base64-encoded JSON lines with Anthropic events.
              log.debug { "bedrock.provider.invoke_model_stream: stream class=#{stream.class}" }

              stream.on_chunk_event do |event|
                raw = event.respond_to?(:bytes) ? event.bytes : nil
                raw = raw.read if raw.respond_to?(:read)
                next unless raw&.length&.positive?

                # Bedrock invoke_model_with_response_stream payloads are gzip-compressed.
                # Detect gzip magic bytes (0x1f8b) and decompress.
                require 'zlib'
                raw = Zlib::GzipReader.wrap(StringIO.new(raw), &:read) if raw.byteslice(0, 2) == "\x1f\x8b"

                # Now raw is UTF-8 JSON lines (newline-delimited Anthropic events)
                text = raw.force_encoding('UTF-8')
                text.lines.each do |line|
                  line = line.strip
                  next if line.empty?

                  raw_event = Legion::JSON.parse(line, symbolize_names: false)
                  next unless raw_event.is_a?(Hash)

                  event_type = raw_event['type'] || 'unknown'
                  state[:raw_events] << { event: event_type, data: raw_event } if dump_path
                  handle_invoke_model_stream_json(raw_event, state, mid) { |chunk| yield chunk if block_given? }
                end
              rescue StandardError => e
                log.warn { "bedrock.provider.invoke_model_stream: chunk decode error=#{sanitize_log(e.message)}" }
              end

              stream.on_error_event do |event|
                log.warn do
                  "bedrock.provider.invoke_model_stream: error event ivars=#{event.instance_variables.inspect}"
                end
              end

              stream.on_internal_server_exception_event do |event|
                log.warn do
                  'bedrock.provider.invoke_model_stream: internal_server_exception ' \
                    "ivars=#{event.instance_variables.inspect}"
                end
              end

              stream.on_model_stream_error_exception_event do |event|
                log.warn do
                  "bedrock.provider.invoke_model_stream: model_stream_error ivars=#{event.instance_variables.inspect}"
                end
              end
            end
            # rubocop:enable Metrics/BlockLength

            # Dump raw streaming events for debugging
            if dump_path && state[:raw_events].any?
              begin
                dump_file = File.join(dump_path, "bedrock_invoke_stream_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
                File.write(dump_file, Legion::JSON.pretty_generate(state[:raw_events]))
                log.debug do
                  "bedrock.provider.invoke_model_stream: #{state[:raw_events].size} raw events dumped to #{dump_file}"
                end
              rescue StandardError => e
                log.warn { "bedrock.provider.invoke_model_stream: failed to dump raw events: #{e.message}" }
              end
            end

            usage = state[:final_usage] || {}
            msg_attrs = {
              role: :assistant,
              content: state[:accumulated],
              model_id: mid,
              tool_calls: build_stream_tool_calls(state[:tool_use_blocks]),
              input_tokens: usage.fetch(:input_tokens, 0) || usage.fetch('input_tokens', 0),
              output_tokens: usage.fetch(:output_tokens, 0) || usage.fetch('output_tokens', 0),
              cached_tokens: usage.fetch(:cache_read_input_tokens, nil) || usage.fetch('cache_read_input_tokens', nil),
              cache_creation_tokens: usage.fetch(:cache_creation_input_tokens,
                                                 nil) || usage.fetch('cache_creation_input_tokens', nil),
              stop_reason: state[:stop_reason]
            }
            msg_attrs[:thinking] = state[:thinking] unless state[:thinking].empty?

            Legion::Extensions::Llm::Message.new(**msg_attrs)
          end

          def build_invoke_model_body(messages:, temperature:, max_tokens:, tools:, tool_prefs:, thinking:,
                                      _model: nil, _streaming: false)
            body = {
              max_tokens: max_tokens || 4096,
              messages: format_invoke_model_messages(messages),
              anthropic_version: 'bedrock-2023-05-31'
            }
            body[:temperature] = temperature if temperature
            if tools && !tools.empty?
              tool_format = format_invoke_model_tools(tools, tool_prefs)
              body[:tools] = tool_format[:tools]
              body[:tool_choice] = tool_format[:tool_choice] if tool_format[:tool_choice]
            end
            body[:thinking] = invoke_model_thinking(thinking) if thinking
            # NOTE: Don't include body[:stream] = true in the JSON body for invoke_model_with_response_stream.
            # The endpoint itself implies streaming; Bedrock rejects the extra field.
            body
          end

          # Strip provider-specific keys (e.g. effort from OpenAI) that Bedrock/Anthropic APIs don't accept.
          def invoke_model_thinking(thinking)
            return thinking unless thinking.is_a?(Hash)

            thinking.except(:effort, 'effort')
          end

          def format_invoke_model_messages(messages)
            messages.filter_map do |msg|
              role = msg.respond_to?(:role) ? msg.role.to_s : (msg[:role] || msg['role']).to_s
              next if role == 'system'

              content = case role
                        when 'tool'
                          format_invoke_model_tool_result(msg)
                        when 'assistant'
                          format_invoke_model_assistant(msg)
                        else
                          format_invoke_model_content(msg)
                        end

              next if content.nil? || (content.is_a?(Array) && content.empty?)

              { role: role, content: content }
            end
          end

          def format_invoke_model_content(msg)
            content = msg.respond_to?(:content) ? msg.content : (msg[:content] || msg['content'])
            return [] if content.nil?

            if content.is_a?(String)
              [{ type: 'text', text: content }]
            elsif content.is_a?(Array)
              content.filter_map do |block|
                type = (block[:type] || block['type']).to_s
                next { type: 'text', text: block[:text] || block['text'] } if type == 'text'

                block
              end
            else
              [{ type: 'text', text: content.to_s }]
            end
          end

          def format_invoke_model_tool_result(msg)
            tool_call_id = if msg.respond_to?(:tool_call_id)
                             msg.tool_call_id
                           else
                             msg[:tool_call_id] || msg['tool_call_id']
                           end
            content = if msg.respond_to?(:tool_results)
                        msg.tool_results.to_s
                      else
                        (msg[:content] || msg['content']).to_s
                      end
            [{ type: 'tool_result', tool_use_id: tool_call_id, content: [{ type: 'text', text: content }] }]
          end

          def format_invoke_model_assistant(msg)
            blocks = []

            text = msg.respond_to?(:content) ? msg.content : (msg[:content] || msg['content'])
            text_str = text.to_s
            blocks << { type: 'text', text: text_str } unless text_str.strip.empty?

            tool_calls = msg.respond_to?(:tool_calls) ? msg.tool_calls : (msg[:tool_calls] || msg['tool_calls'] || {})
            call_array = tool_calls.is_a?(Hash) ? tool_calls.values : Array(tool_calls)

            call_array.each do |call|
              call_id = call.respond_to?(:id) ? call.id : (call[:id] || call['id'])
              call_name = call.respond_to?(:name) ? call.name : (call[:name] || call['name'])
              call_args = if call.respond_to?(:arguments)
                            call.arguments
                          else
                            call[:arguments] || call['arguments'] || {}
                          end

              blocks << {
                type: 'tool_use',
                id: call_id,
                name: call_name,
                input: call_args
              }
            end

            blocks
          end

          def format_invoke_model_tools(tools, tool_prefs)
            tool_list = tools.values.map do |tool|
              {
                name: tool[:name] || tool['name'],
                description: tool[:description] || tool['description'] || '',
                input_schema: tool[:params_schema] || tool['params_schema'] ||
                  { type: 'object', properties: {} }
              }
            end

            result = { tools: tool_list }

            if tool_prefs
              choice = tool_prefs[:choice] || tool_prefs['choice']
              result[:tool_choice] = if [:required, 'required'].include?(choice)
                                       { type: 'any' }
                                     elsif choice.to_s != 'auto' && !choice.to_s.empty?
                                       { type: 'tool', name: choice.to_s }
                                     else
                                       { type: 'auto' }
                                     end
            end

            result
          end

          def parse_invoke_model_response(response, model_id)
            body_raw = value(response, :body)
            body_raw = body_raw.read if body_raw.respond_to?(:read)
            body_raw = body_raw.string if body_raw.respond_to?(:string)
            body = Legion::JSON.parse(body_raw, symbolize_names: false)
            build_invoke_model_message(body, model_id)
          end

          def parse_invoke_model_response_hash(body, model_id)
            # body is already a parsed Hash from Legion::JSON.parse
            build_invoke_model_message(body, model_id)
          end

          def build_invoke_model_message(body, model_id)
            content_blocks = body['content'] || []

            text_parts = content_blocks.filter_map { |b| b['text'] if b['type'] == 'text' }.join
            thinking_text = content_blocks.filter_map { |b| b['thinking'] if b['type'] == 'thinking' }.join
            tool_calls_raw = content_blocks.select { |b| b['type'] == 'tool_use' }

            tc = {}
            tool_calls_raw.each do |tc_block|
              tc[tc_block['id']] = Legion::Extensions::Llm::ToolCall.new(
                id: tc_block['id'], name: tc_block['name'], arguments: tc_block['input'] || {}
              )
            end

            usage = body['usage'] || {}

            msg_attrs = {
              role: :assistant,
              content: text_parts,
              model_id: model_id,
              tool_calls: tc.empty? ? nil : tc,
              input_tokens: usage['input_tokens'] || 0,
              output_tokens: usage['output_tokens'] || 0,
              cached_tokens: usage['cache_read_input_tokens'],
              cache_creation_tokens: usage['cache_creation_input_tokens']
            }
            msg_attrs[:thinking] = thinking_text unless thinking_text.empty?

            Legion::Extensions::Llm::Message.new(**msg_attrs)
          end

          def handle_invoke_model_stream_json(event_json, state, model_id)
            # event_json is a Hash like { "type": "message_start", "message": { ... } }
            case event_json['type']
            when 'message_start'
              msg = event_json['message'] || {}
              state[:final_usage] = msg['usage'] || {}
            when 'content_block_start'
              block = event_json['content_block'] || {}
              block_type = block['type'].to_s
              state[:in_thinking] = (block_type == 'thinking')
              if block_type == 'tool_use'
                state[:current_tool_use] = {
                  tool_use_id: block['id'],
                  name: block['name'],
                  input_json: +''
                }
              elsif block_type != 'thinking'
                state[:in_thinking] = false
              end
            when 'content_block_delta'
              delta = event_json['delta'] || {}
              delta_type = delta['type'].to_s
              case delta_type
              when 'thinking_delta'
                text = delta['thinking'] || ''
                state[:thinking] << text
                if block_given? && !text.empty?
                  yield Legion::Extensions::Llm::Chunk.new(
                    role: :assistant,
                    content: '',
                    thinking: { content: text, enabled: true },
                    model_id: model_id
                  )
                end
              when 'text_delta'
                text = delta['text'] || ''
                state[:accumulated] << text
                if block_given?
                  yield Legion::Extensions::Llm::Chunk.new(role: :assistant, content: text,
                                                           model_id: model_id)
                end
              when 'input_json_delta'
                partial = delta['partial_json'] || ''
                state[:current_tool_use][:input_json] << partial
                if block_given? && !partial.empty?
                  yield Legion::Extensions::Llm::Chunk.new(
                    role: :assistant,
                    content: '',
                    tool_calls: {
                      state[:current_tool_use][:tool_use_id].to_sym =>
                        Legion::Extensions::Llm::ToolCall.new(
                          id: state[:current_tool_use][:tool_use_id],
                          name: state[:current_tool_use][:name],
                          arguments: partial
                        )
                    },
                    model_id: model_id
                  )
                end
              end
            when 'content_block_stop'
              if state[:current_tool_use]
                state[:tool_use_blocks] << state[:current_tool_use]
                state[:current_tool_use] = nil
              end
            when 'message_delta'
              delta = event_json['delta'] || {}
              state[:stop_reason] = delta['stop_reason']
            end
          rescue StandardError => e
            log.warn { "bedrock.provider.invoke_model_stream_json: error=#{e.message}" }
          end

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

          def model_info_from_summary(summary)
            model = value(summary, :model_id)
            input_mods = Array(value(summary, :input_modalities)).map { |m| m.to_s.downcase }
            output_mods = Array(value(summary, :output_modalities)).map { |m| m.to_s.downcase }

            Legion::Extensions::Llm::Model::Info.new(
              id: model,
              name: alias_for(model) || model,
              provider: :bedrock,
              family: (normalize_provider(value(summary, :provider_name)) || model_family_for(model)).to_s,
              capabilities: capabilities_from_modalities(input_mods, output_mods, summary),
              modalities_input: input_mods,
              modalities_output: output_mods,
              metadata: normalize_response(summary)
            )
          end

          def build_offering(model:, model_family:, usage_type:, instance_id: :default, alias_name: nil,
                             capabilities: nil, metadata: {})
            limits = infer_limits(model)
            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :bedrock,
              instance_id: instance_id,
              transport: offering_transport,
              tier: offering_tier,
              model: model,
              usage_type: usage_type,
              capabilities: capabilities || default_capabilities(model),
              limits: limits,
              metadata: metadata.merge(model_family: model_family, alias: alias_name).compact
            )
          end

          def infer_limits(model)
            detail = model_detail(model.to_s)
            return detail if detail.is_a?(Hash) && detail[:context_window]

            ctx = CONTEXT_WINDOWS.find { |prefix, _| model.to_s.start_with?(prefix) }&.last
            ctx ? { context_window: ctx } : {}
          end

          def fetch_model_detail(model_name)
            ctx = CONTEXT_WINDOWS.find { |prefix, _| model_name.start_with?(prefix) }&.last
            ctx ? { context_window: ctx } : nil
          end

          def converse_request(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:, guardrail_config: nil,
                               thinking: nil)
            {
              model_id: self.class.inference_profile_id(model_id(model), region: region),
              messages: format_messages(messages.reject { |message| message.role == :system }),
              system: format_system(messages),
              inference_config: { temperature: temperature, max_tokens: max_tokens || model_max_tokens(model) }.compact,
              tool_config: format_tool_config(tools, tool_prefs),
              guardrail_config: guardrail_config,
              additional_model_request_fields: bedrock_additional_fields(thinking)
            }.compact
          end

          def bedrock_additional_fields(thinking)
            fields = {}
            if thinking
              fields[:thinking] = {
                type: 'enabled',
                budget_tokens: if thinking.is_a?(Hash)
                                 thinking[:budget_tokens] || thinking['budget_tokens'] ||
                                   thinking[:budget] || thinking['budget'] || 1024
                               else
                                 1024
                               end
              }
            end
            fields.empty? ? nil : fields
          end

          def format_messages(messages)
            total = messages.size
            messages.filter_map.with_index do |message, idx|
              blocks = build_content_blocks(message)
              next if blocks.empty?

              cache_blocks = should_cache_message?(idx, total) ? add_cache_control_to_blocks(blocks) : blocks
              { role: bedrock_role(message.role), content: cache_blocks }
            end
          end

          def tool_result_blocks(message)
            return [] unless message.tool_result?

            [{
              tool_result: {
                tool_use_id: message.tool_call_id,
                content: [{ text: message.tool_results.to_s }]
              }
            }]
          end

          def should_cache_message?(index, total)
            # Cache first 4 messages, never the last message
            return false if index == total - 1

            index < 4
          end

          def add_cache_control_to_blocks(blocks)
            # Bedrock Converse API does not support cache_control on text/image/document blocks.
            # Only tool_use blocks support it via the InputMember cache_control field.
            # Return blocks unchanged to avoid SDK union validation errors.
            blocks
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

          def build_content_blocks(message)
            return tool_result_blocks(message) if message.role == :tool

            # Assistant messages with tool calls: build text + tool_use blocks
            return assistant_tool_use_blocks(message) if message.role == :assistant && message.tool_call?

            content_blocks(message.content)
          end

          def assistant_tool_use_blocks(message)
            blocks = []
            text = content_text(message.content)
            blocks << { text: text } if text && !text.strip.empty?

            message.tool_calls.each_value do |call|
              blocks << {
                tool_use: {
                  tool_use_id: call.id,
                  name: call.name,
                  input: call.arguments || {}
                }
              }
            end
            blocks
          end

          def content_blocks(content)
            raw = raw_content(content)
            return raw if raw

            return image_blocks(content) if content.respond_to?(:attachments) && !content.attachments.empty?

            text = content_text(content)
            return [] if text.strip.empty?

            [{ text: text }]
          end

          def image_blocks(content)
            blocks = []
            text = content_text(content)
            blocks << { text: text } if text.strip.present?

            content.attachments.each do |attachment|
              if attachment.is_a?(Legion::Extensions::Llm::Content::ImageAttachment)
                blocks << format_image_attachment(attachment)
              end
            end
            blocks
          end

          def format_image_attachment(attachment)
            {
              image: {
                format: image_format(attachment.format),
                source: { bytes: attachment.data }
              }
            }
          end

          def image_format(fmt)
            case fmt.to_s.downcase
            when 'jpeg', 'jpg' then 'jpeg'
            when 'png' then 'png'
            when 'gif' then 'gif'
            when 'webp' then 'webp'
            end || 'jpeg'
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

            log.debug do
              "bedrock.provider.tools: formatting tools=#{tools.keys.map(&:to_s).sort.join(',')} " \
                "tool_choice=#{tool_choice_label(tool_prefs)}"
            end
            {
              tools: tools.values.map { |tool| tool_definition_with_cache(tool) },
              tool_choice: tool_choice(tool_prefs)
            }.compact
          end

          def tool_definition_with_cache(tool)
            tool_definition(tool)
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

          def tool_choice_label(tool_prefs)
            return 'none' unless tool_prefs

            (tool_prefs[:choice] || tool_prefs['choice'] || 'unspecified').to_s
          end

          def parse_converse_response(response, fallback_model)
            output = value(response, :output)
            message = value(output, :message)
            content_blocks = value(message, :content)
            usage = value(response, :usage) || {}
            additional_fields = value(response, :additional_model_response_fields)

            msg_attrs = {
              role: :assistant,
              content: text_from(content_blocks),
              model_id: fallback_model,
              tool_calls: parse_tool_calls(content_blocks),
              input_tokens: value(usage, :input_tokens),
              output_tokens: value(usage, :output_tokens),
              cached_tokens: cache_read_tokens(usage),
              cache_creation_tokens: cache_write_tokens(usage),
              raw: normalize_response(response)
            }

            # Bedrock Converse returns thinking in two possible locations:
            # 1. Content blocks: { reasoning: { text: "..." } }
            # 2. Additional model response fields: { thinking: { reasoningContent: { chunk: { text } } } }
            thinking_text = extract_thinking_from_content(content_blocks) ||
                            (additional_fields ? extract_thinking_from_fields(additional_fields) : nil)
            msg_attrs[:thinking] = thinking_text if thinking_text

            Legion::Extensions::Llm::Message.new(**msg_attrs)
          end

          def extract_thinking_from_content(content_blocks)
            return nil unless content_blocks

            Array(content_blocks).each do |block|
              reasoning = value(block, :reasoning)
              # reasoning can be a Hash or an AWS SDK struct (Aws::BedrockRuntime::Types::ReasoningContent)
              next if reasoning.nil?

              text = if reasoning.is_a?(Hash)
                       reasoning[:text] || reasoning['text']
                     else
                       # AWS SDK struct — use value() to safely extract the :text field
                       value(reasoning, :text)
                     end
              return text.to_s unless text.to_s.empty?
            end
            nil
          end

          def extract_thinking_from_fields(additional_fields)
            thinking = additional_fields[:thinking] || additional_fields['thinking']
            return nil unless thinking.is_a?(Hash)

            # Bedrock Converse API returns thinking in multiple shapes depending on model:
            # - Claude direct: { text: "..." }
            # - Claude via Converse: { reasoningContent: { chunk: { text: "..." } } }
            # - Some models: { reasoning_text: "..." } or { reasoning: "..." }
            content = thinking[:text] || thinking['text'] ||
                      thinking[:reasoning_text] || thinking['reasoningText'] ||
                      thinking[:reasoning] || thinking['reasoning'] ||
                      reasoning_content_text(thinking)
            content.to_s unless content.to_s.empty?
          end

          def reasoning_content_text(thinking)
            rc = thinking[:reasoningContent] || thinking['reasoningContent']
            return nil unless rc.is_a?(Hash)

            # Handle the nested chunk structure from Bedrock Converse
            chunk = rc[:chunk] || rc['chunk']
            if chunk.is_a?(Hash)
              chunk[:text] || chunk['text']
            else
              rc[:text] || rc['text']
            end
          end

          def stream_converse(request, fallback_model)
            state = { accumulated: +'', thinking: +'', final_usage: nil, stop_reason: nil,
                      tool_use_blocks: [], current_tool_use: nil, in_thinking: false,
                      raw_events: [] }

            log.debug do
              "bedrock.provider.stream_converse: starting model=#{fallback_model} tools=#{state[:tool_use_blocks].size}"
            end

            dump_path = ENV.fetch('BEDROCK_DEBUG_OUTPUT', nil)

            runtime_client.converse_stream(**request) do |stream|
              wire_stream_handlers(stream, state, fallback_model) { |chunk| yield chunk if block_given? }

              # Capture all raw events for debugging
              if dump_path
                stream.on_content_block_start_event do |evt|
                  state[:raw_events] << { event: 'content_block_start', data: safe_event_data(evt) }
                end
                stream.on_content_block_delta_event do |evt|
                  state[:raw_events] << { event: 'content_block_delta', data: safe_event_data(evt) }
                end
                stream.on_content_block_stop_event do |evt|
                  state[:raw_events] << { event: 'content_block_stop', data: safe_event_data(evt) }
                end
                stream.on_message_start_event do |evt|
                  state[:raw_events] << { event: 'message_start', data: safe_event_data(evt) }
                end
                stream.on_message_stop_event do |evt|
                  state[:raw_events] << { event: 'message_stop', data: safe_event_data(evt) }
                end
                stream.on_metadata_event do |evt|
                  state[:raw_events] << { event: 'metadata', data: safe_event_data(evt) }
                end
              end
            end

            # Dump raw streaming events for debugging
            if dump_path && state[:raw_events].any?
              begin
                dump_file = File.join(dump_path, "bedrock_stream_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
                File.write(dump_file, Legion::JSON.pretty_generate(state[:raw_events]))
                log.debug do
                  "bedrock.provider.stream_converse: #{state[:raw_events].size} raw events dumped to #{dump_file}"
                end
              rescue StandardError => e
                log.warn { "bedrock.provider.stream_converse: failed to dump raw events: #{e.message}" }
              end
            end

            log.debug do
              "bedrock.provider.stream_converse: completed model=#{fallback_model} " \
                "accumulated_length=#{state[:accumulated].length} thinking_length=#{state[:thinking].length} " \
                "tool_use_blocks=#{state[:tool_use_blocks].size} stop_reason=#{state[:stop_reason]}"
            end

            msg_attrs = {
              role: :assistant,
              content: state[:accumulated],
              model_id: fallback_model,
              tool_calls: build_stream_tool_calls(state[:tool_use_blocks]),
              input_tokens: value(state[:final_usage], :input_tokens),
              output_tokens: value(state[:final_usage], :output_tokens),
              cached_tokens: cache_read_tokens(state[:final_usage]),
              cache_creation_tokens: cache_write_tokens(state[:final_usage]),
              stop_reason: state[:stop_reason]
            }
            msg_attrs[:thinking] = state[:thinking] unless state[:thinking].empty?
            Legion::Extensions::Llm::Message.new(**msg_attrs)
          end

          def wire_stream_handlers(stream, state, fallback_model, &)
            wire_block_start(stream, state)
            wire_block_delta(stream, state, fallback_model, &)
            wire_block_stop(stream, state)
            wire_message_stop(stream, state)
            stream.on_metadata_event { |event| state[:final_usage] = value(event, :usage) }
          end

          def wire_block_start(stream, state)
            return unless stream.respond_to?(:on_content_block_start_event)

            stream.on_content_block_start_event do |event|
              start = value(event, :start)

              # Bedrock Converse uses 'reasoning' blocks for thinking content,
              # and 'thinking' blocks for legacy/direct invoke_model responses
              if value(start, :thinking) || value(start, :reasoning)
                state[:in_thinking] = true
                next
              end

              state[:in_thinking] = false
              tool_start = value(start, :tool_use) if start
              next unless tool_start

              state[:current_tool_use] = {
                tool_use_id: value(tool_start, :tool_use_id),
                name: value(tool_start, :name),
                input_json: +''
              }
            end
          end

          def wire_block_delta(stream, state, fallback_model)
            stream.on_content_block_delta_event do |event|
              delta = value(event, :delta)
              # Bedrock streaming: text blocks use delta.text,
              # reasoning/thinking blocks use delta.reasoning.text or delta.thinking.text
              text = value(delta, :text) ||
                     (value(delta, :reasoning) ? value(reasoning_delta, :text) : nil) ||
                     (value(delta, :thinking) ? value(thinking_delta, :text) : nil)
              if text
                if state[:in_thinking]
                  state[:thinking] << text
                else
                  state[:accumulated] << text
                  if block_given?
                    yield Legion::Extensions::Llm::Chunk.new(role: :assistant, content: text,
                                                             model_id: fallback_model)
                  end
                end
              end

              tool_input = value(delta, :tool_use)
              next unless tool_input && state[:current_tool_use]

              input_chunk = value(tool_input, :input)
              state[:current_tool_use][:input_json] << input_chunk.to_s if input_chunk
            end
          end

          def wire_block_stop(stream, state)
            return unless stream.respond_to?(:on_content_block_stop_event)

            stream.on_content_block_stop_event do |_event|
              next unless state[:current_tool_use]

              state[:tool_use_blocks] << state[:current_tool_use]
              state[:current_tool_use] = nil
            end
          end

          def wire_message_stop(stream, state)
            return unless stream.respond_to?(:on_message_stop_event)

            stream.on_message_stop_event do |event|
              state[:stop_reason] = value(event, :stop_reason)
            end
          end

          def build_stream_tool_calls(tool_use_blocks)
            return nil if tool_use_blocks.empty?

            tool_use_blocks.to_h do |block|
              input = begin
                Legion::JSON.load(block[:input_json])
              rescue StandardError
                {}
              end
              name = block[:name]
              id = block[:tool_use_id] || name
              [id, Legion::Extensions::Llm::ToolCall.new(id: id, name: name, arguments: input)]
            end
          end

          def cache_read_tokens(usage)
            return nil if usage.nil?

            value(usage, :cache_read_input_tokens) || value(usage, 'cache_read_input_tokens')
          end

          def cache_write_tokens(usage)
            return nil if usage.nil?

            value(usage, :cache_creation_input_tokens) || value(usage, 'cache_creation_input_tokens')
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
            @bedrock_client ||= Aws::Bedrock::Client.new(client_options)
          end

          def runtime_client
            @runtime_client ||= Aws::BedrockRuntime::Client.new(client_options)
          end

          def client_options
            opts = {
              region: region,
              endpoint: config.bedrock_endpoint,
              stub_responses: config.bedrock_stub_responses
            }

            if bearer_token_configured?
              opts[:token_provider] = Aws::StaticTokenProvider.new(config.bearer_token)
            else
              opts[:credentials] = credentials
            end

            opts.compact
          end

          def bearer_token_configured?
            config.respond_to?(:bearer_token) && !config.bearer_token.to_s.empty?
          end

          def credentials
            return Aws::SharedCredentials.new(profile_name: config.bedrock_profile) if config.bedrock_profile
            return nil unless config.bedrock_access_key_id

            if static_credentials_blocked?
              raise SecurityError,
                    'Static AWS credentials are disabled (security.block_static_aws_credentials=true); use IAM roles'
            end
            log.warn('[bedrock] Using static AWS credentials — prefer IAM roles for production')
            Aws::Credentials.new(config.bedrock_access_key_id, config.bedrock_secret_access_key,
                                 config.bedrock_session_token)
          end

          def static_credentials_blocked?
            return false unless defined?(::Legion::Settings)

            ::Legion::Settings.dig(:extensions, :llm, :security, :block_static_aws_credentials) == true
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

          def capabilities_from_modalities(input_mods, output_mods, summary)
            caps = []
            caps << :embedding if output_mods.include?('embedding')
            unless caps.include?(:embedding)
              caps << :completion
              caps << :streaming if value(summary, :response_streaming_supported)
            end
            caps << :vision if input_mods.include?('image')
            caps << :tools if caps.include?(:completion)
            caps
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

          # Safely extract event data for debugging — AWS SDK structs
          # may or may not respond to #to_h
          def safe_event_data(evt)
            evt.respond_to?(:to_h) ? evt.to_h : evt.inspect[0, 500]
          end

          def normalize_response(response)
            response.respond_to?(:to_h) ? response.to_h : {}
          end

          def value(object, key)
            return nil if object.nil?

            string_key = key.to_s

            val = safe_struct_access(object, key)
            return val unless val.nil?

            val = safe_struct_access(object, string_key)
            return val unless val.nil?

            return object.public_send(key) if object.respond_to?(key)

            if object.respond_to?(:to_h)
              hash = object.to_h
              return hash[key] if hash.key?(key)
              return hash[string_key] if hash.key?(string_key)
            end

            nil
          end

          # Sanitize potentially binary/non-UTF-8 strings for safe logging
          def sanitize_log(str)
            return str unless str.is_a?(String)

            str.force_encoding('UTF-8').scrub('?')
          rescue StandardError
            str.inspect
          end

          def safe_struct_access(object, key)
            return nil unless object.respond_to?(:key?) && object.key?(key)

            object[key]
          rescue NameError
            # AWS SDK structs (Aws::Structure) define members in their schema
            # but may not populate them in every response. A missing value
            # raises NameError instead of returning nil.
            nil
          end
        end
      end
    end
  end
end
