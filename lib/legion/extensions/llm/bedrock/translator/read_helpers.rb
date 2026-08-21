# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        class Translator
          # Low-level key-access helpers for reading from Hashes, AWS SDK
          # Struct objects, and canonical model objects in a uniform way.
          module ReadHelpers
            private

            # Try each key in order; return first non-nil value.
            def read_from(obj, *keys)
              return nil unless obj

              keys.each do |key|
                val = try_read_key(obj, key)
                return val unless val.nil?
              end
              nil
            end

            def try_read_key(obj, key)
              if obj.is_a?(Hash)
                obj[key]
              elsif obj.respond_to?(key)
                begin
                  obj.public_send(key)
                rescue StandardError => e
                  handle_exception(e, level: :debug, handled: true,
                                      operation: 'bedrock.translator.read_from')
                  nil
                end
              elsif obj.respond_to?(:to_h) && obj.to_h.key?(key)
                obj.to_h[key]
              end
            end

            def safe_read(obj, sym_key, str_key, default = nil)
              return obj[sym_key] || obj[str_key] || default if obj.is_a?(Hash)

              safe_key_read(obj, sym_key) || default
            end

            def safe_key_read(obj, key)
              return nil unless obj

              if obj.is_a?(Hash)
                obj[key] || obj[key.to_s]
              elsif obj.respond_to?(:key?) && obj.key?(key)
                begin
                  obj[key]
                rescue NameError, NoMethodError => e
                  handle_exception(e, level: :debug, handled: true,
                                      operation: 'bedrock.translator.safe_key_read')
                  nil
                end
              elsif obj.respond_to?(key)
                begin
                  obj.public_send(key)
                rescue NameError, NoMethodError => e
                  handle_exception(e, level: :debug, handled: true,
                                      operation: 'bedrock.translator.safe_key_read')
                  nil
                end
              end
            end

            def nested_read(obj, *keys)
              current = obj
              keys.each do |key|
                return nil unless current.is_a?(Hash)

                current = current[key]
              end
              current
            end

            # B4: the provider translator consumes the selected model — it
            # does not choose or default one. The Selection owns the model
            # (R4); routing/metadata[:model] is the carried fact and a missing
            # model is a contract error (the messages.first.model
            # response-provenance fallback is deleted — PR #45 law).
            def model_from_request(canonical)
              model = canonical.routing[:model] || canonical.metadata[:model]
              if model.nil?
                raise ArgumentError,
                      'bedrock.render_request: no model in request; routing must select a model'
              end

              model
            end

            def converse_role(role)
              role == :assistant ? 'assistant' : 'user'
            end

            # Canonical content (String | ContentBlock | Array<ContentBlock>
            # | nil) to plain text — one strict extraction (B22: the dual
            # Hash reads are deleted; the request normalizer guarantees the
            # shape).
            def convert_to_text(content)
              case content
              when ::String then content.strip
              when Canonical::ContentBlock then content.text.to_s
              when ::Array
                content.filter_map { |c| c.is_a?(Canonical::ContentBlock) ? c.text.to_s : nil }.join
              else
                content.to_s
              end
            end

            def map_stop_reason(raw)
              return nil if raw.nil? || raw.to_s.empty?

              STOP_REASON_MAP.fetch(raw.to_s, raw.to_sym)
            end

            def parse_usage(usage_raw)
              return Canonical::Usage.from_hash({}) unless usage_raw

              h = build_usage_hash(usage_raw)
              Canonical::Usage.from_hash(h)
            end

            def build_usage_hash(usage_raw)
              if usage_raw.is_a?(Hash)
                {
                  input_tokens: usage_raw[:input_tokens] || usage_raw['input_tokens'],
                  output_tokens: usage_raw[:output_tokens] || usage_raw['output_tokens'],
                  cache_read_tokens: usage_raw[:cache_read_input_tokens] || usage_raw['cache_read_input_tokens'],
                  cache_write_tokens: usage_raw[:cache_creation_input_tokens] ||
                    usage_raw['cache_creation_input_tokens'],
                  thinking_tokens: usage_raw[:thinking_tokens] || usage_raw['thinking_tokens']
                }
              else
                {
                  input_tokens: safe_key_read(usage_raw, :input_tokens),
                  output_tokens: safe_key_read(usage_raw, :output_tokens),
                  cache_read_tokens: safe_key_read(usage_raw, :cache_read_input_tokens),
                  cache_write_tokens: safe_key_read(usage_raw, :cache_creation_input_tokens),
                  thinking_tokens: safe_key_read(usage_raw, :thinking_tokens)
                }
              end
            end
          end
        end
      end
    end
  end
end
