# lex-llm-bedrock

Amazon Bedrock provider extension for `Legion::Extensions::Llm`.

This gem adds a hosted Bedrock provider surface for Legion LLM routing without depending on the old `legion-llm` gem. It uses the official AWS SDK for Ruby and keeps discovery offline by default, so loading the extension or running tests does not require live AWS credentials.

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

## API Contract

The implementation is intentionally limited to Bedrock operations documented by AWS:

- `ListFoundationModels` for live model discovery
- `Converse` for chat-style inference
- `ConverseStream` for streaming chat responses
- `CountTokens` for token estimates
- `InvokeModel` only for the Titan text embedding request shape implemented here

Provider-specific request bodies are not guessed. Non-Titan embedding models raise until their documented body shape is added explicitly.

AWS references:

- [Converse](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html)
- [ConverseStream](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ConverseStream.html)
- [CountTokens](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_CountTokens.html)
- [ListFoundationModels](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModels.html)
- [Foundation model information](https://docs.aws.amazon.com/bedrock/latest/userguide/foundation-models-reference.html)
