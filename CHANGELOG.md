# Changelog

## 0.3.18 - 2026-06-05

### Fixed
- **Spec and RuboCop compliance** — Verified all 54 specs pass cleanly. RuboCop auto-correct applied; 0 offenses remaining.

## 0.3.17 - 2026-06-05

### Fixed
- **Unused method arguments** — Prefixed unused keyword parameters (`params`, `model`, `streaming`) in `invoke_model_chat`, `invoke_model_stream`, and `build_invoke_model_body` with underscore prefix to satisfy RuboCop `Lint/UnusedMethodArgument` (provider.rb)
- **Keyword parameter ordering** — Moved optional keyword parameters to the end of `build_invoke_model_body` signature per `Style/KeywordParametersOrder` (provider.rb)

## 0.3.16 - 2026-06-04

### Fixed
- **Thinking config silently ignored by Converse API for Claude Sonnet 4+** — Bedrock Converse API does not support extended thinking for Claude Sonnet 4 and newer. When thinking is enabled for an Anthropic model, the provider now routes through `invoke_model` with the native Anthropic Messages API payload (the same format Phase 1 direct tests use), which correctly generates and returns thinking blocks (provider.rb)
- **Thinking extraction failed on AWS SDK structs** — `extract_thinking_from_content` assumed content blocks were Hashes. Bedrock Converse returns `Aws::BedrockRuntime::Types` structs that don't respond to `[]` the same way. Now uses `value()` helper for safe struct access on reasoning content blocks (provider.rb)
- **Streaming reasoning/thinking blocks not detected** — `wire_block_start` only checked `:thinking` blocks but Bedrock Converse uses `:reasoning` blocks for thinking content. Added `:reasoning` check. `wire_block_delta` now extracts from `delta.reasoning.text` and `delta.thinking.text` in addition to `delta.text` (provider.rb)

### Added
- **Debug logging for Bedrock converse calls** — Logs thinking config sent, elapsed time, usage, additional_fields keys, and content block types on response. Logs stream completion with accumulated length, tool use block count, and stop reason (provider.rb)

## 0.3.15 - 2026-06-04

### Fixed
- **Thinking config ignored in chat/stream/complete** — The `chat`, `stream`, and `complete` methods accepted `thinking:` kwarg but never passed it to Bedrock's converse API. Now passes thinking through `additional_model_request_fields[:thinking]` with AWS-format `{ type: "enabled", budget_tokens: N }`, accepting both `:budget_tokens` and `:budget` keys for compatibility with Anthropic API format (provider.rb)

## 0.3.14 - 2026-06-04

### Fixed
- **`NameError` on unpopulated AWS SDK struct fields** — `Aws::Structure` objects declare all members in their schema (including `cache_creation_input_tokens`), so `key?` returns `true`, but accessing a missing member raises `NameError` instead of returning `nil`. Added `safe_struct_access` helper that wraps `object[key]` in `rescue NameError → nil`, so unpopulated struct fields gracefully return `nil` instead of crashing the request (provider.rb)

## 0.3.13 - 2026-06-02

### Fixed
- **Tool call iteration crash on Bedrock escalation** — `assistant_tool_use_blocks` iterated `message.tool_calls` (a `Hash`) with `each`, which yields `[key, value]` pairs rather than `ToolCall` objects. Calling `.id` on the Array raised `NoMethodError` on every Bedrock call with tool-call history, tripping the circuit breaker and exhausting the escalation chain. Fixed by using `each_value` (provider.rb)

## 0.3.12 - 2026-06-02

### Fixed
- **ContentBlock union validation errors** — Removed `cache_control` from text blocks, system blocks, and tool definitions. The Bedrock Converse SDK's `ContentBlock` is a strict union (text|image|tool_use|...); adding `cache_control` as a sibling key triggered "multiple values provided to union" and "unexpected value" ArgumentError (provider.rb)
- **Assistant tool_call messages rejected by SDK** — Messages with tool calls were sent as raw content blocks with `:type`/`:content` keys. Now emits proper `{ tool_use: { tool_use_id, name, input } }` blocks via new `build_content_blocks`/`assistant_tool_use_blocks` methods (provider.rb)
- **PROMPT-CACHE-01 reverted** — Bedrock Converse API does not support `cache_control` on text/document/image blocks. The markers added in 0.3.11 are removed (provider.rb)

### Added
- **Per-provider discovery refresh actor** — New `actors/discovery_refresh.rb` that only refreshes Bedrock models, avoiding coupling to other providers' discovery cycles

## 0.3.11 - 2026-05-31

### Security
- **BEDROCK-CRED-01**: Static AWS credentials now emit a deprecation warning. New setting `security.block_static_aws_credentials=true` rejects them entirely, forcing IAM role-based authentication.

### Fixed
- **TRANSLATION-BUG-07**: Bedrock streaming now preserves thinking (chain-of-thought) blocks in the final `Message`. Previously CoT was accumulated by the wire handler but silently dropped from the returned response.

### Added
- **PROMPT-CACHE-01**: System blocks, tool definitions, and early conversation messages (first 4, never the last) now include `cache_control: { type: "cache_control" }` markers for Anthropic prompt caching via Bedrock Converse.
- **PROMPT-CACHE-02**: Response parser extracts `cached_input_tokens` (`cache_read_input_tokens`) and `cache_creation_tokens` (`cache_creation_input_tokens`) from Bedrock usage metadata into `Message#cached_tokens` and `Message#cache_creation_tokens`.

## 0.3.10 - 2026-05-21

- Add `default_transport`/`default_tier` class declarations, remove `configured_transport`/`configured_tier`
- Add `model_allowed?` filtering in `discover_offerings` (handles ModelOffering objects)
- Move `DEFAULT_REGION` to settings[:region]
- Default tier corrected from :frontier to :cloud
- Identity headers included via base provider


## 0.3.9 - 2026-05-18

- Fix streaming tool call parsing: `stream_converse` now handles content_block_start/delta/stop events for tool_use blocks, capturing tool ids, names, and accumulated input JSON. Previously only text deltas were captured and tool calls were silently dropped.


## 0.3.8 - 2026-05-13

- Auto-prefix `us.` on `inference_profile_id` for Anthropic, Meta, Mistral, Cohere, and AI21 models at API call time.
- Filter empty content blocks from messages to satisfy Bedrock validation.
- Wire Bearer token into AWS SDK via `Aws::StaticTokenProvider` to eliminate IMDS timeout on startup.
- Add `source` and `credential_fingerprint` fields to all discovered instances.
- Inject default capabilities into all discovered instances.
- Add static `CONTEXT_WINDOWS` map; `infer_limits` reads from `model_detail` cache instead of live API.
- Override `fetch_model_detail` to return static context window data without a network call.
- Cache live results in `discover_offerings`.
- Add `unresolved_credential?` filter — instances with `vault://` or `env://` credential refs are skipped during registration.
- Inject `default_model` into all discovered instances.

## 0.3.7 - 2026-05-12

- Use `Legion::Logging::Helper` explicitly across Bedrock provider, actor, and fleet runner logging surfaces.
- Add non-sensitive debug logging for Bedrock tool configuration and fleet request routing.
- Report optional actor runtime load failures through `handle_exception` instead of direct warning output.

## 0.3.6 - 2026-05-08

- Accept keyword arguments in `list_models` to match the base provider contract called by `discover_offerings`.

## 0.3.5 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical Bedrock provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Preserve configured transport and tier metadata when Bedrock builds routing offerings.
- Strip temporary generic API key fields from discovered Bedrock instance configs after credential deduplication.
- Clean up provider method signatures and README examples from Copilot review feedback.
- Gate release publishing on the shared security workflow.

## 0.3.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.
- Refresh README architecture, file map, fleet responder, and development verification guidance for the current provider-owned fleet implementation.
- Silence test logging so the required full-suite RSpec gate writes only to the configured output files.

## 0.3.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.3.2 - 2026-05-06

- Enforce the shared keyword-only `lex-llm` provider contract for chat, streaming, embeddings, and token counting.
- Move defaults back to `Legion::Extensions::Llm.provider_settings` with AWS credentials/provider metadata under the default instance and instance-level fleet responder settings.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.3.1 - 2026-05-03

- Normalize generic settings keys to Bedrock provider config keys during instance discovery.
- Support named Bedrock instances from extension settings.

## 0.3.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## 0.2.0 - 2026-04-30

- Adopt lex-llm 0.1.9 base contract: flat `default_settings`, base `RegistryPublisher`, base `RegistryEventBuilder`.
- Replace `provider_settings` call with flat default_settings hash (default_model, region, credentials, whitelist/blacklist, TLS, instances).
- Remove `Provider.register` call; register configuration options directly via `Configuration.register_provider_options`.
- Delete local `RegistryPublisher`, `RegistryEventBuilder`, and `transport/` directory; use parameterized base classes from lex-llm.
- Move `registry_publisher` from `Provider` class method to `Bedrock` module method using `Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :bedrock)`.
- Rewrite `list_models` to return `Model::Info` with `capabilities`, `modalities_input`, and `modalities_output` derived from Bedrock `inputModalities`/`outputModalities`.
- Publish discovered models via `publish_models_async` (base contract) instead of `publish_offerings_async`.
- Bump gemspec dependency to `lex-llm >= 0.1.9`.

## 0.1.5 - 2026-04-30

- Audit logging, rescue blocks, and README for full observability.
- Add `include Legion::Logging::Helper` to Provider, RegistryPublisher, and RegistryEventBuilder.
- Replace all bare rescue blocks with `handle_exception(e, level:, handled:, operation:)` calls.
- Add `log.info` for key actions: chat, stream, embed, health, discovery, list_models.
- Remove custom `log_publish_failure` method in favor of standard `handle_exception`.
- Update README with architecture, file map, dependency table, and development guide.

## 0.1.4 - 2026-04-30

- Add headers: parameter to complete method signature matching base provider contract

## 0.1.3 - 2026-04-28

- Remove the unused runtime `legion/settings` require while preserving the gemspec dependency.

## 0.1.2 - 2026-04-28

- Publish best-effort `llm.registry` live readiness and live foundation-model availability events using `lex-llm` registry envelopes when transport is already available.

## 0.1.1 - 2026-04-28

- Require `lex-llm >= 0.1.5` for the shared model offering, alias, readiness, and fleet lane contract used by Bedrock routing metadata.

## 0.1.0 - 2026-04-28

- Initial Legion::Extensions::Llm Bedrock provider extension scaffold.
- Add offline provider defaults, model offering mapping, AWS SDK client construction, chat, streaming, embeddings, token counting, health, and live discovery entrypoints.
- Add README, gemspec, CI, and stubbed unit specs for Bedrock routing behavior.
