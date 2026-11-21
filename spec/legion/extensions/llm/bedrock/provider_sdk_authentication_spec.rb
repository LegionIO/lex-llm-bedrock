# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'webmock/rspec'
require 'legion/extensions/llm/bedrock/runners/discovery'

RSpec.describe Legion::Extensions::Llm::Bedrock::Provider do
  paths = %i[runtime provider_catalog discovery_catalog discovery_readiness]
  let(:environment_keys) do
    %w[
      AWS_BEARER_TOKEN_BEDROCK AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
      AMAZON_ACCESS_KEY_ID AMAZON_SECRET_ACCESS_KEY AMAZON_SESSION_TOKEN AWS_ACCESS_KEY AWS_SECRET_KEY
      AWS_ACCOUNT_ID AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
      AWS_AUTH_SCHEME_PREFERENCE AWS_EC2_METADATA_DISABLED AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
      AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
      AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_SDK_LOAD_CONFIG
    ].freeze
  end

  around do |example|
    original_environment = environment_keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    original_aws_config = Aws.config.dup
    original_shared_config = Aws.instance_variable_get(:@shared_config)
    environment_keys.each { |key| ENV.delete(key) }
    Aws.config.clear
    Dir.mktmpdir('bedrock-sdk-auth') do |directory|
      @credentials_path = File.join(directory, 'credentials')
      config_path = File.join(directory, 'config')
      File.write(@credentials_path, '')
      File.write(config_path, '')
      ENV['AWS_SHARED_CREDENTIALS_FILE'] = @credentials_path
      ENV['AWS_CONFIG_FILE'] = config_path
      Aws.instance_variable_set(:@shared_config, nil)
      example.run
    end
  ensure
    original_environment.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Aws.config.replace(original_aws_config)
    Aws.instance_variable_set(:@shared_config, original_shared_config)
  end

  before do
    WebMock.disable_net_connect!
    allow(Aws::CredentialProviderChain).to receive(:new).and_call_original
    allow(Aws::InstanceProfileCredentials).to receive(:new).and_call_original
  end

  paths.each do |path|
    context "with #{path} dispatch" do
      it 'uses configured bearer auth without searching the AWS credential chain or IMDS' do
        request = stub_native_request(path: path, authorization: 'Bearer configured-token')

        result = perform_request(path: path, config: { bearer_token: 'configured-token' })

        expect_success(path: path, result: result)
        expect_no_credential_search
        expect(request).to have_been_requested.once
      end

      it 'keeps the configured token when the bearer environment token differs' do
        ENV['AWS_BEARER_TOKEN_BEDROCK'] = 'different-environment-token'
        request = stub_native_request(path: path, authorization: 'Bearer configured-token')

        result = perform_request(path: path, config: { bearer_token: 'configured-token' })

        expect_success(path: path, result: result)
        expect_no_credential_search
        expect(request).to have_been_requested.once
      end

      it 'retains explicit SigV4 credentials when no bearer is configured' do
        request = stub_native_request(path: path, authorization: %r{\AAWS4-HMAC-SHA256 Credential=explicit-key/})

        result = perform_request(path: path, config: {
                                   bedrock_access_key_id: 'explicit-key', bedrock_secret_access_key: 'explicit-secret',
                                   bedrock_session_token: 'explicit-session'
                                 })

        expect_success(path: path, result: result)
        expect_no_credential_search
        expect(request).to have_been_requested.once
      end

      it 'retains the configured shared-credentials profile' do
        File.write(@credentials_path,
                   "[selected]\naws_access_key_id = profile-key\naws_secret_access_key = profile-secret\n")
        request = stub_native_request(path: path, authorization: %r{\AAWS4-HMAC-SHA256 Credential=profile-key/})

        result = perform_request(path: path, config: { bedrock_profile: 'selected' })

        expect_success(path: path, result: result)
        expect_no_credential_search
        expect(request).to have_been_requested.once
      end

      it 'retains the SDK default credential chain when auth is omitted' do
        ENV['AWS_ACCESS_KEY_ID'] = 'environment-key'
        ENV['AWS_SECRET_ACCESS_KEY'] = 'environment-secret'
        request = stub_native_request(path: path, authorization: %r{\AAWS4-HMAC-SHA256 Credential=environment-key/})

        result = perform_request(path: path, config: {})

        expect_success(path: path, result: result)
        expect(Aws::CredentialProviderChain).to have_received(:new).once
        expect(Aws::InstanceProfileCredentials).not_to have_received(:new)
        expect(request).to have_been_requested.once
      end
    end
  end

  it 'propagates invalid configured bearer authentication without trying SigV4' do
    request = stub_request(:post, runtime_url)
              .with(headers: { 'Authorization' => 'Bearer rejected-token' })
              .to_return(status: 403, headers: { 'x-amzn-errortype' => 'AccessDeniedException' },
                         body: Legion::JSON.dump({ message: 'Access denied' }))

    expect do
      perform_request(path: :runtime, config: { bearer_token: 'rejected-token' })
    end.to raise_error(Aws::BedrockRuntime::Errors::AccessDeniedException)
    expect_no_credential_search
    expect(request).to have_been_requested.once
  end

  def expect_no_credential_search
    expect(Aws::CredentialProviderChain).not_to have_received(:new)
    expect(Aws::InstanceProfileCredentials).not_to have_received(:new)
  end

  def runtime_url
    'https://bedrock-runtime.us-east-1.amazonaws.com/model/us.anthropic.claude-sonnet-4-6/invoke'
  end

  def stub_native_request(path:, authorization:)
    if path == :runtime
      body = { id: 'msg_test', type: 'message', role: 'assistant', model: 'claude-sonnet-4-6',
               content: [{ type: 'text', text: 'ok' }], stop_reason: 'end_turn',
               usage: { input_tokens: 3, output_tokens: 1 } }
      stub_request(:post, runtime_url).with(headers: { 'Authorization' => authorization })
                                      .to_return(status: 200, headers: { 'content-type' => 'application/json' },
                                                 body: Legion::JSON.dump(body))
    else
      stub_request(:get, 'https://bedrock.us-east-1.amazonaws.com/foundation-models')
        .with(headers: { 'Authorization' => authorization })
        .to_return(status: 200, headers: { 'content-type' => 'application/json' },
                   body: Legion::JSON.dump({ modelSummaries: [] }))
    end
  end

  def perform_request(path:, config:)
    instance = { bedrock_region: 'us-east-1' }.merge(config)
    case path
    when :runtime
      provider = Legion::Extensions::Llm::Bedrock::Provider.new(instance)
      provider.chat(messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Hello')],
                    model: 'anthropic.claude-sonnet-4-6',
                    params: Legion::Extensions::Llm::Canonical::Params.build(max_tokens: 2048),
                    thinking: Legion::Extensions::Llm::Canonical::Thinking::Config.build(budget: 1024))
    when :provider_catalog
      Legion::Extensions::Llm::Bedrock::Provider.new(instance).send(:bedrock_client).list_foundation_models
    when :discovery_catalog
      Legion::Extensions::Llm::Bedrock::Runners::Discovery.fetch_raw_models(instance_cfg: instance)
    when :discovery_readiness
      Legion::Extensions::Llm::Bedrock::Runners::Discovery.check_health(instance_cfg: instance)
    end
  end

  def expect_success(path:, result:)
    case path
    when :runtime
      expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(result.text).to eq('ok')
    when :provider_catalog then expect(result.model_summaries).to eq([])
    when :discovery_catalog then expect(result).to eq([])
    when :discovery_readiness then expect(result.ready).to be(true)
    end
  end
end
