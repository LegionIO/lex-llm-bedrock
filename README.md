# lex-llm-bedrock

Amazon Bedrock provider extension for `Legion::Extensions::Llm`.

This gem adds a hosted Bedrock provider surface for Legion LLM routing. It uses the official AWS SDK for Ruby and keeps discovery offline by default, so loading the extension or running tests does not require live AWS credentials. It requires `lex-llm >= 0.4.3` for the shared provider contract, response normalization, model offering, readiness, fleet envelope contract, and provider-owned fleet responder execution.

## Architecture

```
Legion::Extensions::Llm::Bedrock
├── Provider                    # Bedrock implementation of the lex-llm Provider contract
│   ├── Capabilities            # Capability predicates inferred from model IDs
│   ├── chat / stream           # Converse / ConverseStream API calls
│   ├── embed                   # Titan InvokeModel embedding
│   ├── count_tokens            # CountTokens API call
│   ├── discover_offerings      # Static catalog + live ListFoundationModels
│   ├── health / readiness      # Provider health checks with live AWS verification
│   ├── list_models             # Live model enumeration
│   ├── invoke_model_chat       # Native Anthropic payload for thinking-enabled models
│   └── invoke_model_stream     # Native Anthropic streaming for thinking-enabled models
├── Actor::FleetWorker          # Provider-owned fleet subscription gate
├── Actor::DiscoveryRefresh     # Periodic model catalog refresh (conditional on actor runtime)
└── Runners::FleetWorker        # Delegates fleet requests to lex-llm ProviderResponder
```

### Provider Dispatch

The `Provider` class decides at call time which API path to use:

| Condition | Path | Why |
|-----------|------|-----|
| Anthropic model + `thinking` or `tools` | `invoke_model` (native Anthropic payload) | Bedrock Converse silently drops thinking config and tool_use blocks for Claude Sonnet 4+ |
| All other cases | `Converse` / `ConverseStream` | Standard Bedrock managed inference API |

### Instance Discovery

`Legion::Extensions::Llm::Bedrock.discover_instances` scans five credential sources in priority order, deduplicates by fingerprint, and returns a hash of `{ instance_name => config_hash }` pairs:

| Source | Key | How it works |
|--------|-----|--------------|
| ENV bearer | `:env_bearer` | Reads `AWS_BEARER_TOKEN_BEDROCK` from environment |
| Claude config bearer | `:claude` | Reads `AWS_BEARER_TOKEN_BEDROCK` from Claude env/config, falls back to pattern match on any key containing `AWS`, `BEARER`, `TOKEN`, `BEDROCK` |
| ENV SigV4 | `:env_sigv4` | Reads `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` from environment |
| Extension settings | `:settings` + named instances | Reads from `extensions.llm.bedrock` settings, normalizes generic keys to `bedrock_*` prefix |
| Identity Broker | `:broker` | Reads `Legion::Identity::Broker.credentials_for(:aws)` when the module is defined |

Instances with unresolved credential references (`vault://` or `env://` URIs) are filtered out.

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
| `lib/legion/extensions/llm/bedrock.rb` | Entry point: namespace, default settings, instance discovery, credential sources, and shared provider registration metadata |
| `lib/legion/extensions/llm/bedrock/provider.rb` | Full Bedrock provider implementation (1500+ lines) — Converse, invoke_model, streaming, tool calls, thinking, embeddings, health, and discovery |
| `lib/legion/extensions/llm/bedrock/actors/fleet_worker.rb` | Starts the provider-owned fleet subscriber when an instance opts in |
| `lib/legion/extensions/llm/bedrock/actors/discovery_refresh.rb` | Periodic model catalog refresh actor (loaded only when `Legion::Extensions::Actors::Every` is available) |
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

Configuration options: `bedrock_region`, `bedrock_endpoint`, `bedrock_access_key_id`, `bedrock_secret_access_key`, `bedrock_session_token`, `bedrock_profile`, `bedrock_stub_responses`, `bearer_token`.

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
messages = [Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')]
model = 'anthropic.claude-3-haiku-20240307-v1:0'
provider.chat(messages: messages, model: model)
provider.stream(messages: messages, model: model) { |chunk| chunk.content }
provider.embed(text: 'hello', model: 'amazon.titan-embed-text-v2:0')
provider.count_tokens(messages: messages, model: model)
```

`discover_offerings(live: false)` returns a small static catalog that is useful for routing defaults and unit tests. `discover_offerings(live: true)` calls Bedrock `ListFoundationModels` and maps the returned model summaries into `Legion::Extensions::Llm::Routing::ModelOffering` records.

## Model Offerings

Every offering uses:

- `provider_family: :bedrock`
- `transport: :aws_sdk`
- the Bedrock model ID as `model`
- `metadata[:model_family]` inferred from the provider prefix or accepted from the caller

Known aliases are intentionally small and conservative. For example, `claude-3-haiku` resolves to `anthropic.claude-3-haiku-20240307-v1:0`, while the preserved Bedrock model ID remains the routing model.

Static models: `claude-3-haiku`, `anthropic.claude-sonnet-4`, `titan-text-express`, `titan-embed-text-v2`, `llama-3.2-11b-instruct`, `mistral-large-3`.

## Inference Profiles

Bare model IDs (e.g. `anthropic.claude-sonnet-4`) are automatically prefixed with the region-based inference profile prefix (`us.`, `eu.`, `ap.`) based on the configured region. Region mapping is defined in `REGION_PREFIX`:

| Region | Prefix |
|--------|--------|
| `us-east-1`, `us-east-2`, `us-west-1`, `us-west-2` | `us` |
| `eu-central-1`, `eu-west-*` | `eu` |
| `ap-south-1`, `ap-southeast-*`, `ap-northeast-1` | `ap` |

Models already prefixed (`us.`, `eu.`, `ap.`, `arn:`) are passed through unchanged.

## Context Windows

Static context window data is available for known models without making live API calls. Looked up by prefix match in `Provider::CONTEXT_WINDOWS`.

| Model prefix | Context |
|-------------|---------|
| `anthropic.claude-*` (all) | 200,000 |
| `meta.llama3*` | 128,000 |
| `mistral.mistral-*` | 128,000 |
| `amazon.nova-pro`, `nova-lite` | 300,000 |
| `amazon.nova-micro` | 128,000 |
| `amazon.titan-text-premier` | 32,000 |
| `amazon.titan-text-express` | 8,192 |

## API Contract

The implementation is intentionally limited to Bedrock operations documented by AWS:

- `ListFoundationModels` for live model discovery
- `Converse` for chat-style inference
- `ConverseStream` for streaming chat responses
- `CountTokens` for token estimates
- `InvokeModel` only for the Titan text embedding request shape implemented here
- `InvokeModel` (non-streaming) for Anthropic models with thinking/tool use enabled
- `InvokeModelWithResponseStream` for Anthropic models with thinking/tool use enabled

Provider-specific request bodies are not guessed. Non-Titan embedding models raise until their documented body shape is added explicitly.

## Tool Calls

Tool calls follow the Bedrock Converse `tool_config` shape. When tool call history is present in the message array, assistant messages emit proper `{ tool_use: { tool_use_id, name, input } }` content blocks. Tool results use `{ tool_result: { tool_use_id, content } }` blocks.

For Anthropic models with tools, the `invoke_model` path is used with native Anthropic tool formatting (`input_schema` wrapped in the tool definition).

## Thinking (Extended Reasoning)

When `thinking:` is passed to `chat`, `stream`, or `complete` for an Anthropic model:

1. The provider detects the Anthropic model prefix and routes through `invoke_model` with the native Anthropic Messages API payload.
2. Thinking config is serialized as `{ type: 'enabled', budget_tokens: N }`, accepting both `:budget_tokens` and `:budget` keys.
3. Provider-specific keys (e.g. `:effort` from OpenAI) are stripped before sending.
4. Responses parse thinking content from `content_blocks[type: 'thinking']` for `invoke_model`, and from `delta.reasoning.text` for `ConverseStream`.

## Security

- Static AWS credentials emit a deprecation warning. Set `security.block_static_aws_credentials: true` in settings to reject them entirely.
- Bearer token authentication is supported via `Aws::StaticTokenProvider`, eliminating IMDS timeout on startup.

## Observability

The Bedrock namespace and provider implementation include `Legion::Logging::Helper` for structured logging:

- **Info-level**: provider connections, API calls (chat, stream, embed), model listing, health checks
- **Debug-level**: offline health checks, readiness probes, token counting, thinking config, request/response metadata
- **Rescue blocks**: handled provider failures call `handle_exception(e, level:, handled:, operation:)` with dot-separated operation names such as `bedrock.provider.health`

Set `BEDROCK_DEBUG_OUTPUT=/path/to/dir` to dump raw Bedrock responses and streaming events to JSON files for debugging.

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A               # auto-fix
bundle exec rubocop                  # lint check (0 offenses expected)
```

### Test Structure

| Spec file | Coverage |
|-----------|----------|
| `bedrock_spec.rb` | Provider surface: offerings, chat, stream, tools, embed, count_tokens, health, readiness, model listing, caching |
| `discover_instances_spec.rb` | Credential discovery from ENV, Claude config, settings, Identity Broker, and deduplication |
| `provider_contract_spec.rb` | Verifies all canonical methods use keyword-only arguments (no positional params) |
| `actors/fleet_worker_spec.rb` | Fleet worker actor: runner class, function, use_runner?, enabled? |
| `runners/fleet_worker_spec.rb` | Fleet worker runner: delegation to shared ProviderResponder |

## AWS References

- [Converse](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html)
- [ConverseStream](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ConverseStream.html)
- [CountTokens](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_CountTokens.html)
- [ListFoundationModels](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModels.html)
- [InvokeModel](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html)
- [Foundation model information](https://docs.aws.amazon.com/bedrock/latest/userguide/foundation-models-reference.html)

## License

MIT
