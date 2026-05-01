# lex-llm-bedrock

Amazon Bedrock provider extension for `Legion::Extensions::Llm`.

This gem adds a hosted Bedrock provider surface for Legion LLM routing without depending on the old `legion-llm` gem. It uses the official AWS SDK for Ruby and keeps discovery offline by default, so loading the extension or running tests does not require live AWS credentials. It requires `lex-llm >= 0.1.5` for the shared model offering, alias, readiness, and fleet lane contract.

## Architecture

```
Legion::Extensions::Llm::Bedrock
├── Provider               # Bedrock implementation of the lex-llm Provider contract
│   ├── Capabilities       # Capability predicates inferred from model IDs
│   ├── chat / stream      # Converse / ConverseStream API calls
│   ├── embed              # Titan InvokeModel embedding
│   ├── count_tokens       # CountTokens API call
│   ├── discover_offerings # Static catalog + live ListFoundationModels
│   ├── health / readiness # Provider health checks with live AWS verification
│   └── list_models        # Live model enumeration
├── RegistryEventBuilder   # Builds sanitized lex-llm registry envelopes
├── RegistryPublisher      # Best-effort async publisher for registry events
└── Transport
    ├── Exchanges::LlmRegistry    # Topic exchange for llm.registry events
    └── Messages::RegistryEvent   # AMQP message for registry event publishing
```

## Dependencies

| Gem | Required | Purpose |
|-----|----------|---------|
| `aws-sdk-bedrock` | Yes | Bedrock management client (ListFoundationModels) |
| `aws-sdk-bedrockruntime` | Yes | Bedrock runtime client (Converse, InvokeModel) |
| `legion-json` (>= 1.2.1) | Yes | JSON serialization |
| `legion-logging` (>= 1.3.2) | Yes | Structured logging via Helper |
| `legion-settings` (>= 1.3.14) | Yes | Configuration |
| `lex-llm` (>= 0.1.5) | Yes | Shared provider contract, model offerings, routing |

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/extensions/llm/bedrock.rb` | Entry point: namespace, default settings, provider registration |
| `lib/legion/extensions/llm/bedrock/provider.rb` | Full Bedrock provider implementation |
| `lib/legion/extensions/llm/bedrock/registry_event_builder.rb` | Builds lex-llm registry event envelopes |
| `lib/legion/extensions/llm/bedrock/registry_publisher.rb` | Best-effort async registry event publishing |
| `lib/legion/extensions/llm/bedrock/transport/exchanges/llm_registry.rb` | AMQP topic exchange definition |
| `lib/legion/extensions/llm/bedrock/transport/messages/registry_event.rb` | AMQP message class for registry events |
| `lib/legion/extensions/llm/bedrock/version.rb` | `VERSION` constant |

## Install

```ruby
gem 'lex-llm-bedrock'
```

## Configuration

The provider registers the `:bedrock` provider family with `Legion::Extensions::Llm::Provider`.

```ruby
require 'legion/extensions/llm/bedrock'

Legion::Extensions::Llm.configure do |config|
  config.bedrock_region = ENV.fetch('AWS_REGION', 'us-east-1')
  config.bedrock_access_key_id = ENV['AWS_ACCESS_KEY_ID']
  config.bedrock_secret_access_key = ENV['AWS_SECRET_ACCESS_KEY']
  config.bedrock_session_token = ENV['AWS_SESSION_TOKEN']
end
```

If explicit keys are not configured, the AWS SDK default credential provider chain is used. Default settings expose `env://` credential references and mark live discovery disabled:

```ruby
Legion::Extensions::Llm::Bedrock.default_settings
```

Configuration options: `bedrock_region`, `bedrock_endpoint`, `bedrock_access_key_id`, `bedrock_secret_access_key`, `bedrock_session_token`, `bedrock_profile`, `bedrock_stub_responses`.

## Provider Surface

```ruby
provider = Legion::Extensions::Llm::Bedrock::Provider.new(Legion::Extensions::Llm.config)

provider.discover_offerings(live: false)
provider.offering_for(model: 'anthropic.claude-3-haiku-20240307-v1:0')
provider.health(live: false)
provider.chat(messages, model: model)
provider.stream(messages, model: model) { |chunk| chunk.content }
provider.embed('hello', model: 'amazon.titan-embed-text-v2:0')
provider.count_tokens(messages, model: model)
```

`discover_offerings(live: false)` returns a small static catalog that is useful for routing defaults and unit tests. `discover_offerings(live: true)` calls Bedrock `ListFoundationModels` and maps the returned model summaries into `Legion::Extensions::Llm::Routing::ModelOffering` records.

## Model Offerings

Every offering uses:

- `provider_family: :bedrock`
- `transport: :aws_sdk`
- the Bedrock model ID as `model`
- `metadata[:model_family]` inferred from the provider prefix or accepted from the caller

Known aliases are intentionally small and conservative. For example, `claude-3-haiku` resolves to `anthropic.claude-3-haiku-20240307-v1:0`, while the preserved Bedrock model ID remains the routing model.

Static models: `claude-3-haiku`, `titan-text-express`, `titan-embed-text-v2`, `llama-3.2-11b-instruct`, `mistral-large-3`.

## API Contract

The implementation is intentionally limited to Bedrock operations documented by AWS:

- `ListFoundationModels` for live model discovery
- `Converse` for chat-style inference
- `ConverseStream` for streaming chat responses
- `CountTokens` for token estimates
- `InvokeModel` only for the Titan text embedding request shape implemented here

Provider-specific request bodies are not guessed. Non-Titan embedding models raise until their documented body shape is added explicitly.

## Observability

All classes include `Legion::Logging::Helper` for structured logging:

- **Info-level**: provider connections, API calls (chat, stream, embed), model listing, health checks
- **Debug-level**: offline health checks, readiness probes, token counting, registry event scheduling
- **Rescue blocks**: every rescue calls `handle_exception(e, level:, handled:, operation:)` with dot-separated operation names (e.g., `bedrock.provider.health`, `bedrock.registry_publisher.publish_event`)

## Development

```bash
bundle install
bundle exec rspec --format progress  # all pass
bundle exec rubocop -A               # auto-fix
bundle exec rubocop                  # lint check (0 offenses expected)
```

## AWS References

- [Converse](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html)
- [ConverseStream](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ConverseStream.html)
- [CountTokens](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_CountTokens.html)
- [ListFoundationModels](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModels.html)
- [Foundation model information](https://docs.aws.amazon.com/bedrock/latest/userguide/foundation-models-reference.html)

## License

MIT
