# frozen_string_literal: true

require 'bundler/setup'
require 'legion/extensions/llm'

# Load the declared host test dependency without starting services or actors.
require 'legion/transport'
require 'legion/extensions/helpers/lex'
require 'legion/extensions/actors/every'
require 'legion/extensions/actors/subscription'

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
