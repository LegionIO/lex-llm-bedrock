# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# Exercise the real host actor definitions and the SDK's HTTP/auth boundary.
group :test do
  gem 'legionio'
  gem 'webmock'
  lex_llm_path = File.expand_path('../lex-llm', __dir__)
  gem 'lex-llm', path: lex_llm_path if Dir.exist?(lex_llm_path)
end

group :development do
  gem 'bundler', '>= 2.0'
  gem 'rake', '>= 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '>= 1.0'
  gem 'rubocop-performance'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec'
end
