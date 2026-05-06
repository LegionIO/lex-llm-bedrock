# lex-llm-bedrock

Amazon Bedrock provider extension for `Legion::Extensions::Llm`.

This gem adds a hosted Bedrock provider surface for Legion LLM routing. It uses the official AWS SDK for Ruby and keeps discovery offline by default, so loading the extension or running tests does not require live AWS credentials. It requires `lex-llm >= 0.4.3` for the shared provider contract, response normalization, model offering, readiness, fleet envelope contract, and provider-owned fleet responder execution.

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
├── Actor::FleetWorker     # Provider-owned fleet subscription gate
└── Runners::FleetWorker   # Delegates fleet requests to lex-llm ProviderResponder
```

## Dependencies

| Gem | Required | Purpose |
|-----|----------|---------|
| `aws-sdk-bedrock` | Yes | Bedrock management client (ListFoundationModels) |
| `aws-sdk-bedrockruntime` | Yes | Bedrock runtime client (Converse, InvokeModel) |
| `legion-json` (>= 1.2.1) | Yes | JSON serialization |
| `legion-logging` (>= 1.3.2) | Yes | Structured logging via Helper |
| `legion-settings` (>= 1.3.14) | Yes | Configuration |
| `lex-llm` (>= 0.4.3) | Yes | Shared provider contract, response normalization, model offerings, fleet envelopes, and fleet responder execution |
| `legion-transport` (>= 1.4.14) | Yes | AMQP subscriptions and replies |

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/extensions/llm/bedrock.rb` | Entry point: namespace, default settings, discovery, and shared provider registration metadata |
| `lib/legion/extensions/llm/bedrock/provider.rb` | Full Bedrock provider implementation |
| `lib/legion/extensions/llm/bedrock/actors/fleet_worker.rb` | Starts the provider-owned fleet subscriber when an instance opts in |
| `lib/legion/extensions/llm/bedrock/runners/fleet_worker.rb` | Hands provider fleet requests to `Legion::Extensions::Llm::Fleet::ProviderResponder` |
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

If explicit keys are not configured, the AWS SDK default credential provider chain is used. Default settings define the Bedrock provider family, default instance metadata, AWS credential slots, and opt-in fleet responder controls:

```ruby
Legion::Extensions::Llm::Bedrock.default_settings
```

Configuration options: `bedrock_region`, `bedrock_endpoint`, `bedrock_access_key_id`, `bedrock_secret_access_key`, `bedrock_session_token`, `bedrock_profile`, `bedrock_stub_responses`.

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one configured instance enables `respond_to_requests`.

```yaml
extensions:
  llm:
    bedrock:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

Fleet execution stays inside this provider extension until the final handoff to `lex-llm`'s shared `ProviderResponder` helper. This gem does not depend on `legion-llm` at runtime.

## Provider Surface

```ruby
provider = Legion::Extensions::Llm::Bedrock::Provider.new(Legion::Extensions::Llm.config)

provider.discover_offerings(live: false)
provider.offering_for(model: 'anthropic.claude-3-haiku-20240307-v1:0')
provider.health(live: false)
provider.chat(messages:, model:)
provider.stream(messages:, model:) { |chunk| chunk.content }
provider.embed(text: 'hello', model: 'amazon.titan-embed-text-v2:0')
provider.count_tokens(messages:, model:)
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

The Bedrock namespace and provider implementation include `Legion::Logging::Helper` for structured logging:

- **Info-level**: provider connections, API calls (chat, stream, embed), model listing, health checks
- **Debug-level**: offline health checks, readiness probes, and token counting
- **Rescue blocks**: handled provider failures call `handle_exception(e, level:, handled:, operation:)` with dot-separated operation names such as `bedrock.provider.health`

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
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
