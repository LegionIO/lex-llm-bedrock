# frozen_string_literal: true

require 'bundler/setup'
require 'legion/extensions/llm'
begin
  require 'legion/extensions/helpers/lex'
rescue LoadError
  # lex helper not available in isolated test environment
end

Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false, color: false)

# register_provider_options is defined in the full runtime but not in the
# standalone Configuration class shipped with lex-llm.  Patch it in so the
# provider file can register its config options during require.
unless Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
  Legion::Extensions::Llm::Configuration.define_singleton_method(:register_provider_options) do |keys|
    Array(keys).each { |k| option(k) }
  end
end

require 'legion/extensions/llm/bedrock'

# Load conformance kit from lex-llm spec/ directory (shipped in gem, not on load path).
# Consumer pattern per B1b report: Gem.loaded_specs + Dir glob.
begin
  lex_llm_path = Gem.loaded_specs['lex-llm']&.full_gem_path
  if lex_llm_path
    kit_path = File.join(lex_llm_path, 'spec', 'legion', 'extensions', 'llm', 'conformance')
    Dir[File.join(kit_path, '**', '*.rb')].each { |f| require f } if Dir.exist?(kit_path)
  end
rescue StandardError => e
  log.warn("Failed to load conformance kit: #{e.message}") if respond_to?(:log)
end
