# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Translator
          # Converse API and invoke_model request rendering helpers.
          module RequestRendering
            private

            def render_converse(canonical)
              mid = model_from_request(canonical)
              payload = {
                model_id: inference_profile_id(mid),
                messages: render_converse_messages(canonical.messages),
                inference_config: build_inference_config(canonical)
              }
              payload[:system] = [{ text: canonical.system.to_s }] if canonical.system && !canonical.system.to_s.empty?
              tool_cfg = build_converse_tool_config(canonical)
              payload[:tool_config] = tool_cfg if tool_cfg
              additional = build_additional_fields(canonical)
              payload[:additional_model_request_fields] = additional if additional
              params = canonical.params
              if params
                payload[:stop_sequences] = params.stop_sequences if params.stop_sequences
                payload[:seed] = params.seed if params.seed
              end
              payload[:stream] = true if canonical.stream
              payload.compact
            end

            def inference_profile_id(model_id)
              return model_id if model_id.nil? || model_id.start_with?('arn:')

              canonical = model_id.sub(/\A(?:us|eu|ap)\./, '')
              return canonical unless MODEL_PREFIXED_FAMILIES.any? { |p| canonical.start_with?(p) }

              "#{normalize_geo_prefix(@geo_prefix)}.#{canonical}"
            end

            def build_inference_config(canonical)
              return {} unless canonical.params

              cfg = {
                max_tokens: canonical.params.max_tokens,
                temperature: canonical.params.temperature
              }
              cfg[:top_p] = canonical.params.top_p if canonical.params.top_p
              if canonical.params.top_k && anthropic_model?(model_from_request(canonical))
                cfg[:top_k] =
                  canonical.params.top_k
              end
              cfg.compact
            end

            def build_additional_fields(canonical)
              return nil unless canonical.thinking
              return nil if ThinkingModes.known_non_thinking?(model_from_request(canonical))

              budget = canonical_thinking_budget(canonical) || (DEFAULT_MAX_TOKENS / 4)
              { thinking: { type: 'enabled', budget_tokens: budget } }
            end

            def normalize_geo_prefix(value)
              candidate = value.to_s.downcase
              %w[us eu ap].include?(candidate) ? candidate : 'us'
            end

            def canonical_thinking_budget(canonical)
              return nil unless canonical.thinking

              if canonical.thinking.respond_to?(:budget) && canonical.thinking.budget
                canonical.thinking.budget
              elsif canonical.params.respond_to?(:max_thinking_tokens) && canonical.params.max_thinking_tokens
                canonical.params.max_thinking_tokens
              end
            end

            def build_converse_tool_config(canonical)
              return nil unless canonical.tools && !canonical.tools.empty?

              tools = canonical.tools.values.map do |tool|
                { tool_spec: { name: tool.name, description: tool.description.to_s,
                               input_schema: { json: tool.parameters } } }
              end

              result = { tools: tools }
              choice = canonical.tool_choice
              result[:tool_choice] = converse_tool_choice(choice) if choice
              result.compact
            end

            def converse_tool_choice(choice)
              return { auto: {} } if choice.nil? || choice == :auto

              case choice
              when :required, 'required' then { any: {} }
              else { tool: { name: choice.to_s } }
              end
            end

            def render_invoke_model(canonical)
              body = {
                max_tokens: canonical.params&.max_tokens || DEFAULT_MAX_TOKENS,
                messages: render_invoke_messages(canonical.messages),
                anthropic_version: 'bedrock-2023-05-31'
              }
              sys = render_invoke_system(canonical)
              body[:system] = sys if sys
              temp = canonical.params&.temperature
              body[:temperature] = temp if temp
              tool_data = build_invoke_tools(canonical)
              body[:tools]       = tool_data[:tools]       if tool_data && tool_data[:tools]
              body[:tool_choice] = tool_data[:tool_choice] if tool_data && tool_data[:tool_choice]
              thinking_cfg = build_invoke_thinking(canonical)
              body[:thinking] = thinking_cfg if thinking_cfg
              body[:stream] = true if canonical.stream
              body.compact
            end

            def build_invoke_thinking(canonical)
              return nil unless canonical.thinking
              return nil if ThinkingModes.known_non_thinking?(model_from_request(canonical))

              budget = canonical_thinking_budget(canonical) || (DEFAULT_MAX_TOKENS / 4)
              { type: 'enabled', budget_tokens: budget }
            end

            def render_invoke_system(canonical)
              sys = canonical.system
              return nil if sys.nil? || sys.to_s.strip.empty?

              if sys.is_a?(Array)
                sys.map do |block|
                  wire = { type: 'text', text: (block[:text] || block['text'] || block.to_s).to_s }
                  cc = block[:cache_control] || block['cache_control']
                  wire[:cache_control] = cc if cc
                  wire
                end
              else
                [{ type: 'text', text: sys.to_s }]
              end
            end

            def build_invoke_tools(canonical)
              return nil unless canonical.tools && !canonical.tools.empty?

              tools = canonical.tools.values.map do |tool|
                { name: tool.name, description: (tool.description || '').to_s,
                  input_schema: tool.parameters }
              end
              result = { tools: tools }
              choice = canonical.tool_choice
              result[:tool_choice] = invoke_tool_choice(choice) if choice
              result
            end

            def invoke_tool_choice(choice)
              return { type: 'auto' } if choice.nil? || choice == :auto

              case choice
              when :required, 'required' then { type: 'any' }
              else { type: 'tool', name: choice.to_s }
              end
            end
          end
        end
      end
    end
  end
end
