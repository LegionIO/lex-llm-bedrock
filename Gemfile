# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :test do
  transport_path = ENV.fetch('LEGION_TRANSPORT_PATH', File.expand_path('../../legion-transport', __dir__))
  gem 'legion-transport', path: transport_path if File.directory?(transport_path)
end

# lex-llm (>= 0.5.0) comes from gemspec with canonical types + conformance kit.
# Override with a path/branch reference for local development only:
#   gem 'lex-llm', path: ENV.fetch('LEX_LLM_PATH', '../lex-llm')

group :development do
  gem 'bundler', '>= 2.0'
  gem 'rake', '>= 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '>= 1.0'
  gem 'rubocop-performance'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec'
end
