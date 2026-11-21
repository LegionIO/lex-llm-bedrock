# frozen_string_literal: true

require 'bundler/setup'
require 'legion/extensions/llm'

# The LegionIO actor runtime (Every/Subscription actor bases, the Lex settings
# helper) is the host platform, not a dependency of this gem. When it is not
# on the load path, provide minimal stand-ins so the production actor files
# load unchanged. Specs that exercise actor logic drive `manual`/`shutdown`
# directly — the stand-in Every starts no timer.
begin
  require 'legion/extensions/helpers/lex'
rescue LoadError
  require 'legion/logging/helper'
  # The module is host-platform; in isolated gem tests mix in the real
  # legion-settings Helper so `settings` exercises the genuine 1.4.2
  # nested-path resolution ([:extensions][:llm][:bedrock]), and the real
  # legion-logging Helper so `log` and `handle_exception` behave as in the
  # daemon (logged, never re-raised).
  module Legion
    module Extensions
      module Helpers
        module Lex
          include ::Legion::Settings::Helper
          include ::Legion::Logging::Helper
        end
      end
    end
  end
end

begin
  require 'legion/extensions/actors/every'
rescue LoadError
  module Legion
    module Extensions
      module Actors
        class Every
          def initialize(**) = nil
        end
      end
    end
  end
end

Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false, color: false)

require 'legion/extensions/llm/bedrock'

# Load the conformance kit from the lex-llm gem (shipped in spec/, not on the
# load path). EXPLICIT file list — never a directory glob: the kit directory
# also ships lex-llm's own self-test specs (echo_translator_spec,
# ssot_provider_conformance_spec), which are lex-llm's to run and LoadError
# outside that repo.
begin
  lex_llm_path = Gem.loaded_specs['lex-llm']&.full_gem_path
  if lex_llm_path
    kit_dir = File.join(lex_llm_path, 'spec', 'legion', 'extensions', 'llm', 'conformance')
    %w[
      conformance.rb
      canonical_type_examples.rb
      client_translator_examples.rb
      provider_translator_examples.rb
      provider_tool_rendering_examples.rb
      ssot_contract_examples.rb
      ssot_provider_examples.rb
    ].each do |kit_file|
      require File.join(kit_dir, kit_file)
    end
  end
rescue StandardError => e
  log.warn("Failed to load conformance kit: #{e.message}") if respond_to?(:log)
end
