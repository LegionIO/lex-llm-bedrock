# Changelog

## [0.5.6] - 2026-08-19

### Changed
- **Canonical dispatch boundary (N x N law)** — The production `BedrockCallable#chat` / `#stream_chat` / `#count_tokens` operations now call `Provider#enforce_canonical_messages!` before dispatch, and the provider's message-conversion seam (`DispatchHelpers#build_provider_messages`) accepts only `Canonical::Message` (pipeline dispatch) or the provider-native `Legion::Extensions::Llm::Message` (Chat facade); anything else raises a loud `ArgumentError`. The lenient message-level hash re-canonicalization that masked the 2026-08-19 hash-bypass defect is removed from the invoke_model render path. Client request formats and the Bedrock wire payload shape are unchanged.
- **Dependency floor** — Requires `lex-llm >= 0.7.7` for `Provider#enforce_canonical_messages!` (the N x N dispatch boundary). The Gemfile adds a local-tree `lex-llm` path dependency to the test group so the adjacent checkout resolves against 0.7.7 during development.

### Added
- **Dispatch-boundary regression guards** — The SSOT v3 conformance spec now asserts that plain-Hash messages are rejected loudly at both the callable dispatch boundary and the provider render seam, and the model-policy / streaming specs that previously fed incidental Hash messages now use canonical inputs.

### 0.8.0 conformance (SSOT v4 provider wave, 2026-08-20)

#### Changed
- **Legacy types migrated to Canonical** — Every provider parse/build path now renders FROM `Canonical::Message` / `Canonical::ContentBlock` and parses TO `Canonical::Response` / `Canonical::Chunk` / `Canonical::ToolCall` / `Canonical::Usage` / `Canonical::Thinking`. The deleted legacy `Llm::Message` / `Llm::Chunk` / `Llm::ToolCall` / `Llm::Content::Raw` / `Llm::Content::ImageAttachment` constructions and the `to_provider_message` re-canonicalization bridge are gone; the provider dispatch seam enforces `Canonical::Message` only.
- **Callable boundary is the 0.8.0 contract** — `BedrockCallable#chat` / `#stream_chat` take messages positionally, matching the base `Provider#chat` signature and the fleet `WorkerExecution` dispatch. The `enforce_canonical_messages!` calls (the one shared lex-llm helper at the exact-execution boundary) and `normalize_dispatch_error(error:)` are kept.
- **Offering read path (07 C5)** — The legacy `Routing::ModelOffering` production chain in the provider (`discover_offerings` override, `offering_for`, `offering_from_model`, `offering_from_summary`, `build_offering`, `static_offerings` and their filter helpers) is deleted; the base `Provider#discover_offerings` serves the activated inventory offerings from `Registry.snapshot`. The discovery actor's `OfferingDraft` writer path is the sole publication path.
- **Streaming is canonical end-to-end** — Both streaming paths (Converse events and invoke_model Anthropic events) yield `Canonical::Chunk` objects (`text_delta` / `thinking_delta` / `tool_call_delta`) and the sequence ends in exactly one `done` chunk carrying usage + stop_reason; the accumulated state builds a `Canonical::Response`. Tool-input JSON fragments travel on the `tool_call_delta` chunk and are parsed once at stream end.
- **Sync parse boundary** — The Converse and invoke_model sync parsers delegate to the gem's canonical `Translator` (one parse boundary); the `content_filtered` / `content_filter` wire stop-reason spellings map to canonical `:content_filter` at that single edge.
- **Embed artifact (05 §3 / O07)** — `parse_embedding_response` returns the documented Hash artifact `{ text:, model:, embedding:, usage: Canonical::Usage }` (the deleted `Llm::Embedding` type is gone).

#### Removed
- **Legacy coordinator wiring** — The `ScopedRefresher::LegacyCoordinatorAdapter` compatibility adapter (and the `scoped_refresher` require) is removed from the discovery actor's `Publisher` construction; the mixed-version window is over with the lex-llm 0.8.0 cut.

#### Added
- **Conformance kit B1/B2** — The SSOT v3 conformance spec now loads the 0.8.0 boundary kit (`ssot_contract_examples.rb`) and runs the B1 (central canonical enforcement) and B2 (canonical outputs) shared example groups against the real `BedrockCallable` -> `Bedrock::Provider` -> stubbed-AWS-SDK boundary.
- **RULES.md** — The 0.8.0 architecture law (`references/01-rules-draft.md`, byte-for-byte) ships at the repo root.

#### Dependency
- **Floor bump** — Requires `lex-llm >= 0.8.0` (the contract cut: canonical strictification, legacy rip, provider funnel, fleet v3, conformance kit).

## [0.5.5] - 2026-08-19

### Added
- **Callable-path system conformance** — The production `BedrockCallable#chat` path now has a rendered-wire fixture proving a folded leading system message reaches the AWS Converse payload's native `system` field.

### Changed
- **Write-time SSOT lane weights** — Bedrock discovery computes the shared four-component weight pair for every offering, reconciles weight-only changes on the existing `Actors::Every` cadence, and publishes immutable weighted snapshots without adding a Settings callback, reload path, restart, migration, or operator step.
- **Atomic writer lifecycle** — Initial and recovery activation, ordinary replacement, state removal, sequence allocation, cached offerings, and dormant-weight tracking now share one actor mutex. Initializing states never replace, failed publisher calls leave the cache retryable, and late readiness cannot resurrect a removed state.
- **Dependency floor** — Requires `lex-llm >= 0.7.6` for `WeightSchema`, weighted Inventory records, `WeightReconciler`, and `DormantWeightTracker`; the existing `legion-settings >= 1.4.2` floor is unchanged.

### Fixed
- **Startup validation cannot orphan an initializing claim** — Initial offering construction and write-time weight validation now finish before Bedrock creates a callable or probe coordinator and before Inventory issues a publisher token. A malformed weight leaves no Registry status, callable, token, or actor state; the next corrected cadence claims and activates normally.
- **Ordinary discovery compares the complete offering contract** — Replacement detection now retains every authoritative `OfferingDraft` field and ignores only evidence observation timestamps. Catalog order is set-like while duplicate multiplicity remains visible, so metadata, quota, evidence-source/value, publication-source, native-key, capability, operation, tier, or weight drift publishes exactly once without churn from reorder-only discovery.

## [0.5.4] - 2026-08-18

### Fixed
- **Synthetic default is claimable** — Removed the discovery skip branch and once-per-boot warning for the synthetic `instances.default` configuration; normal credential validation now decides whether it can be activated.

## [Unreleased]

### Changed
- **Config-name instance identity (fail-forward)** — the discovery actor now claims instances under the operator's CONFIG NAME (`InstanceKey.instance_id`, the key the router looks up in `instances.<name>`); the derived `region/<credential>` id becomes the SECONDARY `InstanceKey.physical_id` (dedup/diagnostics only — it never participates in identity, tuning, or routing). `InstanceIdentity.derive_instance_id` is renamed `derive_physical_id`; every `Publisher` call carries `physical_id:`; the state map and tick reconciliation are keyed by the config name; a config literally named `default` (the reserved `InstanceKey` identity) is skipped with a loud warn instead of an every-tick `ValidationError`. Offering metadata records `instance_id` (name) + `physical_id` (derived). Conformance harness + actor/actor-lifecycle specs assert the name-based identity with the secondary physical id. Embedding models already publish `chat: :unsupported` (authoritative operation evidence — unchanged). The gemspec floor rises to `lex-llm >= 0.7.1` (the `physical_id` InstanceKey contract is 0.7.1-only).

### Fixed
- **Synthetic-default skip warn fires once per boot** — the unmodified `instances.default` template skip WARN now fires exactly once per actor lifetime (a provider with no claimed instance is the normal state; a per-tick WARN was permanent log noise). The operator signal — "default is still the unmodified template; set real credentials to publish it" — is preserved at first occurrence.
- **Single actor registration** — the provider module no longer extends Core at file level, so the boot-time submodule walk skips it (its `autobuild` gate) and the gem's own top-level extension load is the sole actor registration (eliminates the double-claim / `FencedPublisherError`).
- **Real fleet dispatch (D1)** — `BedrockCallable` now implements `chat` / `stream_chat` / `embed` / `count_tokens` with `**` passthrough, delegating to a per-instance `Bedrock::Provider` built from the instance config; provider/AWS errors propagate unchanged for `normalize_dispatch_error`. `disconnect` closes the wrapped provider; dispatching a disconnected callable raises. Conformance harness now uses the PRODUCTION callable (the `TrackingBedrockCallable` stub is gone) and the exact fleet dispatch test drives a real `callable -> Provider -> stubbed Converse` round-trip.
- **No fallback identity (D3)** — credential-less instance configs (including the synthetic `instances.default`) are never claimed; `Bedrock::InstanceIdentity.derive_instance_id` returns `nil` instead of a `default-chain` id. The `credentials:` sub-hash is flattened in `normalize_instance_config`, and `enabled: false` instances are skipped. The conformance spec no longer asserts the forbidden `ap-southeast-1/default-chain` identity.
- **Initial-failure recovery (D4)** — an instance stuck in `:initializing` after a failed startup probe is re-probed each tick and re-activated (fresh offerings + `activate_instance_snapshot`) on the first passing probe. Ticks also reconcile the instance set: instances configured after boot are claimed, instances whose configuration disappeared (or changed) are removed/re-claimed. Offering comparison is on identity/status, not `Data#==`, so an unchanged catalog no longer forces a replace every tick.
- **Mixed-version bridge (D2)** — the actor's `Inventory::Publisher` injects `LegacyCoordinatorAdapter` so SSOT publications are projected to the old coordinator store during the mixed-version window.
- **Single discovery universe (P2-3)** — the actor and the fleet worker/runner both source instances from `Bedrock.discover_instances` (settings + env + claude + sigv4 + broker, deduped), so an env-credentialed node publishes SSOT lanes and can answer fleet requests.
- **Security setting path (P2-2)** — `security.block_static_aws_credentials` is read at its registered path (`extensions.llm.bedrock.security`) via explicit `dig`; the silent `rescue NoMethodError, TypeError` is gone.
- **Fleet Subscription dispatch (D13)** — `Actor::FleetWorker#runner_class` returns the runner constant (a String cannot be `send`-ed by the Subscription path) and `Runners::FleetWorker#handle_fleet_request(**message)` accepts the decoded message exactly as the framework invokes it.
- **Provider dispatch surface** — `chat` / `stream` / `embed` / `count_tokens` merge `**opts` passthrough params into the API payload instead of silently dropping them; `complete` accepts the base contract's `headers:` via accept-and-ignore `**` (it was `_headers:`, an `ArgumentError` on the inherited `stream_chat` path).
- **Discovery cadence (D9)** — the actor `time` reads the registered `discovery.interval_seconds` (never nil; falls back to the registered default) and the dead `self.every_seconds` is removed. The shadow top-level `discovery_interval` default is dropped in favor of the single standard knob.
- **Health display (D14)** — after every registry commit (initial readiness, recovery activation, replace, probe, removal) the actor writes `settings[:instances][<config_name>][:health]` (legacy 4-key shape + display keys) and `[:capabilities]`; removal clears them. Routing authority remains the in-memory availability state.
- **Standards sweep** — `require` instead of `require_relative` across lib; the hard-dep `NameError` guard in `BedrockCallable#overloaded_error?` and the silent settings rescue in `ClientHelpers` are removed; `**_provider_options` / `_headers:` kwargs replaced per the kwarg signature rule.
- **Conformance kit load** — spec_helper requires the kit's `conformance.rb` + `ssot_provider_examples.rb` instead of globbing the whole directory, which was executing lex-llm's own self-test specs inside this gem's suite. New actor lifecycle spec covers claimability, `enabled: false`, D4 recovery, tick reconciliation, shutdown, D14 health shape, and D9 cadence.
- **Raw-string model (D15)** — verified: bedrock's render path normalizes the model through `Capabilities#model_id` (string-safe: `model.respond_to?(:id) ? model.id.to_s : model.to_s`) at every dispatch op (chat/stream/count_tokens/embed/invoke-model paths), so no `Model::Info` wrap is needed at the callable boundary. Pinned by new conformance tests driving the production callable with a raw string model. (Note: offline `stub_responses` clients cannot exercise `converse_stream`/`invoke_model` — an upstream aws-sdk-core stubbing limitation, verified against the raw SDK; the model-handling path is the same `model_id` chokepoint.)
- **Discovery fail-loud (D16)** — `discover_offerings_for_instance` and `check_health` re-raise `NameError`/`NoMethodError`/`ArgumentError` instead of converting them into "no offerings"/"readiness failed" (which would leave every instance invisibly empty); only network/runtime errors yield `[]`/a failed probe. The conformance harness now delegates draft-building and safe-readiness to the PRODUCTION actor methods (`build_offering_draft`, `check_health`) — the duplicated harness evidence builders are deleted. No class constant is referenced from an included helper module (`DEFAULT_DISCOVERY_INTERVAL_SECONDS` is class-local to `time`; `CONTEXT_WINDOWS` lives in its own module).
- **Stale lock (D10)** — `Gemfile.lock` regenerated against `lex-llm >= 0.7.0` (was pinned to 0.6.9, which cannot load the SSOT inventory layer).

## [0.5.2] - 2026-08-13

### Fixed
- **Genuine rubocop compliance** — Removed every `# rubocop:disable` inline directive and all `.rubocop.yml` weakening. Added `Metrics/ClassLength: Max: 1500` / `Metrics/ModuleLength: Max: 1500` matching the project-wide shared standard used by all other `lex-llm-*` gems. Extracted provider helpers into seven modules under `provider/` and translator helpers into five modules under `translator/` to achieve real separation, not suppression.
- **Superclass mismatch** — `provider/constants.rb` now specifies `class Provider < Legion::Extensions::Llm::Provider` and requires `legion/extensions/llm` so the first file to open the class always sets the correct superclass.
- **`resolve_model_id` kwargs** — Changed `_config: nil` (wrong name) to `**` so the method correctly absorbs the `config:` keyword that `lex-llm` passes via `provider_resolved_model_id`.
- **`known_non_thinking?` semantics** — Now returns `false` for non-Claude/non-Anthropic model IDs (including test fixtures). Thinking is only suppressed for models that positively match the Claude family but are not in the budgeted-thinking list, preventing 500s on Bedrock without over-restricting unknown models.
- **Secondary publication engine removed** — `publish_readiness_async` and `publish_models_async` calls removed from provider instance methods (§2/§5). Corresponding test expectations removed from `bedrock_spec.rb`.
- **Stale/superseded probe tests** — Rewrote conformance spec stale and superseded probe tests to use the correct `readiness_succeeded` probe lifecycle rather than `activate_instance_snapshot` (which requires `:initializing` state). The stale probe check relies on `started_availability_revision < unavailable_revision`; superseded probe correctness is verified by showing a double `readiness_succeeded` leaves the instance intact.
- **Spec path alignment** — Moved `provider/capability_policy_spec.rb` and `provider/thinking_capability_spec.rb` to `bedrock/provider_*_spec.rb` to satisfy `RSpec/SpecFilePathFormat`. Renamed `thinking_payload_spec.rb` to `provider_thinking_payload_spec.rb` and removed the non-method second `describe` argument to fix `RSpec/DescribeMethod`.

## [0.5.1] - 2026-08-13

### Fixed
- **SSOT v3 compliance sweep** — Removed all `# rubocop:disable` directives from source and specs. Replaced swallowed `rescue nil` in probe cleanup with `handle_exception` logging. Removed `|| default` settings guards by registering `discovery_interval:` in `default_settings`. Removed `:default` instance_id fallbacks from `offering_for` and `build_offering`. Split `DiscoveryRefresh` into six focused private modules to satisfy `Metrics/ClassLength` and `Metrics/ModuleLength` without inline disables.
- **Health firewall** — `connection_failure` / timeout / overload / generic-5xx remain request-local; only `Aws::BedrockRuntime::Errors::ServiceUnavailableException` maps to `:instance_unavailable`. Conformance harness mapping corrected.

## [0.5.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration** — Discovery actor completely rewritten to use `Inventory::Publisher`, `ProbeCoordinator`, and `BedrockCallable`. Each credential/region pair publishes as an exact instance with full operation evidence per model. No default model, no Legion::LLM reverse dependency.
- **Dependency floor** — `lex-llm >= 0.7.0` (Inventory v3 API).
- **Removed** `DEFAULT_MODEL` constant, `resolve_default_model`, and default model injection from `discover_instances`. SSOT v3 forbids provider-level model defaults — the router selects models from published offerings.

### Added
- **BedrockCallable** — Implements `disconnect` and `normalize_dispatch_error` with full AWS error classification. Only `Aws::BedrockRuntime::Errors::ServiceUnavailableException` maps to `:instance_unavailable`; all other 5xx/transient errors map to `:overloaded`.
- **Conformance spec** — `it_behaves_like 'an SSOT v3 provider adapter'` plus Bedrock-specific identity derivation, error classification, and isolation tests.

## [0.4.10] - 2026-08-04

### Fixed
- **Claude models now advertise the `:thinking` capability.** Discovery passed `provider_catalog: {}` to `CapabilityPolicy.resolve`, so per-model capabilities from the shared lex-llm catalog (which correctly tags Claude 3.7 / 4+ models `reasoning` → `:thinking`) were ignored — every Bedrock Claude model reported no thinking capability, so the router's thinking filter could not route thinking requests correctly. `offering_from_model` now consults the shared catalog via `catalog_capabilities`.
- **Thinking payload no longer sends unsupported `adaptive` mode.** `invoke_model_thinking` / `build_invoke_thinking` (and the converse-path `bedrock_additional_fields` / `build_additional_fields`) previously emitted `{type: 'adaptive'}` for every non-`claude-sonnet-4` model, which Bedrock rejects with `ValidationException: adaptive thinking is not supported on this model` (HTTP 500, e.g. claude-opus-4-5). A new `ThinkingModes` module is the single source of truth shared by provider and translator: budgeted-thinking models emit `{type: 'enabled', budget_tokens: N}`; known non-thinking models omit thinking entirely. `adaptive` is never emitted.

## [0.4.9] - 2026-06-20

### Fixed
- Stub shared registry publishing through `RegistryPublisher#schedule` in specs so async availability-event coverage stays stable after the shared publisher moved off raw `Thread.new`.

## [0.4.8] - 2026-06-20

### Fixed
- Stop bulk-publishing Bedrock model availability from `list_models`; discovery now emits one registry event per seen model from the shared `lex-llm` policy-filter path so blocked models stay observable without duplicate publishes.

## [0.4.7] - 2026-06-20

### Fixed
- Stop deriving Bedrock `us.`/`eu.`/`ap.` inference-profile prefixes from AWS regions. Model invocation now strips any existing geo prefix and prepends only an explicit Bedrock geo prefix setting, defaulting to `us`.

## [0.4.6] - 2026-06-20

### Fixed
- Canonicalize Bedrock embedding discovery to the shared singular `:embedding` capability and route provider/instance/model override extraction through the `lex-llm` base provider contract.

## [0.4.5] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.4.4 - 2026-06-17

### Fixed
- **Model policy enforced at dispatch (compliance)** — Bedrock overrides the base dispatch methods (`chat`, `stream`, `embed`), so the base `enforce_model_allowed!` guard did not apply. Each override now calls `enforce_model_allowed!(model_id(model))`, raising `ModelNotAllowedError` before any Bedrock API call when the model is excluded by `model_whitelist`/`model_blacklist`. Fail-closed, no exceptions.

### Changed
- **Policy-aware default model** — the `anthropic.claude-sonnet-4` default is no longer a hardcoded literal forced via `||=`; it is a named `DEFAULT_MODEL` constant resolved through `Provider.policy_safe_default_model`, so a configured whitelist/blacklist is never overridden by the fallback. Requires lex-llm >= 0.5.4.

## 0.4.3 - 2026-06-16

- Dependency updates and code quality improvements.

## 0.4.2 - 2026-06-15

- **CapabilityPolicy integration** — AWS model summaries used as `:model_metadata`; Converse tool use from `:provider_envelope`. Settings overrides at provider/instance/model level supported.

## 0.4.1 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **RuboCop fixes** — Auto-corrected 6 offenses (style/layout).
- 199 examples, 0 failures; 17 files, 0 rubocop offenses.

## 0.4.0 - 2026-06-10

### Added
- **Canonical provider translator** — New `Legion::Extensions::Llm::Bedrock::Translator` class implementing the canonical translator interface per Phase 3 of the N×N routing design. Supports `render_request`, `parse_response`, `parse_chunk`, and `capabilities`. Extracted from existing `format_messages`, `format_tools`, `parse_*` provider code (provider.rb) — move and normalize, no semantic rewrites.
- **Dual render targets** — Translator renders canonical requests to both Bedrock Converse API (`:converse`) and Bedrock invoke_model with Anthropic Messages payload (`:invoke_model`). Auto-selection: Anthropic models with thinking or tools route through invoke_model, all other requests use Converse.
- **Conformance kit adoption** — Loads `it_behaves_like 'a canonical provider translator'` shared examples from lex-llm. Full fixture-driven conformance with simple text, system prompt, params, tools, thinking, multi-turn continuation, streaming (text/thinking/tool call), error, stop_reason mapping, and round-trip consistency.
- **Canonical capabilities declaration** — `capabilities` declares `provider: 'bedrock'`, `render_targets: [:converse, :invoke_model]`, `thinking: :budget_tokens`, `stop_reasons` mapping (including `guardrail_intervened` → `content_filter`).

### Changed
- **lex-llm dependency** — Bumped to `lex-llm >= 0.5.0` for canonical types (Request/Response/Chunk/Params/Thinking/ToolCall/Usage/Message/ContentBlock/ToolDefinition) and conformance kit availability.
- **Version bump** — Minor version 0.3.x → 0.4.0 (additive feature release).

### Fixed
- **Params handling** — Translator uses `Canonical::Params.from_hash` instead of non-existent `Params.build`. All 187 specs pass.
- **Content block type/Access** — Translator correctly handles both Hash-inputs and `Canonical::ContentBlock` Data-struct objects with `.type`/`.text` attribute accessors.

## 0.3.19 - 2026-06-10

### Fixed
- **Tool role mapped incorrectly for Bedrock Converse** — Bedrock Converse API does not accept `role: 'tool'`; tool results must use `role: 'user'`. `format_invoke_model_messages` now remaps tool-role messages to user-role before serialization (provider.rb).
- **Unused keyword parameters in build_invoke_model_body** — Replaced explicit unused `_model`/`_streaming` kwargs with `**_rest` splat to capture and discard any extra keywords cleanly (provider.rb).
- **Spec helper LoadError** — Wrapped `require 'legion/extensions/helpers/lex'` in rescue block so specs load in isolated environments where the lex helper gem is absent. Added `register_provider_options` monkey-patch for standalone Configuration compatibility (spec_helper.rb).

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
