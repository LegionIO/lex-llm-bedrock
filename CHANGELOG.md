# Changelog

## 0.1.2 - 2026-04-28

- Publish best-effort `llm.registry` live readiness and live foundation-model availability events using `lex-llm` registry envelopes when transport is already available.

## 0.1.1 - 2026-04-28

- Require `lex-llm >= 0.1.5` for the shared model offering, alias, readiness, and fleet lane contract used by Bedrock routing metadata.

## 0.1.0 - 2026-04-28

- Initial Legion::Extensions::Llm Bedrock provider extension scaffold.
- Add offline provider defaults, model offering mapping, AWS SDK client construction, chat, streaming, embeddings, token counting, health, and live discovery entrypoints.
- Add README, gemspec, CI, and stubbed unit specs for Bedrock routing behavior.
