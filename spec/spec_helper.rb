# frozen_string_literal: true

require 'bundler/setup'
require 'legion/extensions/llm'
require 'legion/extensions/llm/bedrock'

Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false, color: false)
