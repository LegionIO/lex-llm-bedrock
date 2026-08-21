# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Bedrock
        # One owner for the render-side max_tokens decision (B18): the
        # Canonical::Params member is authoritative; a missing value defaults
        # once, identically, at this owner — invoke_model requires the field
        # on the wire (4096), Converse omits it (the API default applies).
        # The fork by model object type (a Model::Info with max_output_tokens
        # metadata winning over a String model id) is deleted: the same
        # canonical request renders the same wire regardless of the model's
        # object wrapping (R13).
        module RenderDefaults
          DEFAULT_MAX_TOKENS = 4096

          module_function

          # @param params [Canonical::Params, nil]
          # @param target [:converse, :invoke_model]
          # @return [Integer, nil]
          def max_tokens(params, target:)
            params&.max_tokens || (target == :invoke_model ? DEFAULT_MAX_TOKENS : nil)
          end
        end
      end
    end
  end
end
