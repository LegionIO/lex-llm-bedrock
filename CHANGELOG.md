# Changelog

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
