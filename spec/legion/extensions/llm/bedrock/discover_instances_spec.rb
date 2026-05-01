# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Bedrock, '.discover_instances' do
  subject(:discover) { described_class.discover_instances }

  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }

  before do
    allow(credential_sources).to receive_messages(
      env: nil,
      claude_env_value: nil,
      claude_config_value: nil,
      setting: nil
    )
    hide_const('Legion::Identity::Broker')
  end

  describe 'bearer token via ENV' do
    it 'returns :env_bearer when AWS_BEARER_TOKEN_BEDROCK is set' do
      allow(credential_sources).to receive(:env).with('AWS_BEARER_TOKEN_BEDROCK').and_return('tok-env')
      allow(credential_sources).to receive(:env).with('AWS_DEFAULT_REGION').and_return('us-west-2')

      expect(discover).to include(
        env_bearer: {
          bearer_token: 'tok-env',
          bedrock_region: 'us-west-2',
          tier: :cloud
        }
      )
    end

    it 'defaults region to us-east-2 when AWS_DEFAULT_REGION is unset' do
      allow(credential_sources).to receive(:env).with('AWS_BEARER_TOKEN_BEDROCK').and_return('tok-env')

      expect(discover[:env_bearer][:bedrock_region]).to eq('us-east-2')
    end

    it 'omits :env_bearer when AWS_BEARER_TOKEN_BEDROCK is not set' do
      expect(discover).not_to have_key(:env_bearer)
    end
  end

  describe 'bearer token via Claude config' do
    it 'returns :claude when claude_env_value has the exact key' do
      allow(credential_sources).to receive(:claude_env_value)
        .with('AWS_BEARER_TOKEN_BEDROCK').and_return('tok-claude')
      allow(credential_sources).to receive(:claude_env_value)
        .with('AWS_DEFAULT_REGION').and_return('eu-west-1')

      expect(discover).to include(
        claude: {
          bearer_token: 'tok-claude',
          bedrock_region: 'eu-west-1',
          tier: :cloud
        }
      )
    end

    it 'falls back to pattern match when exact key is missing' do
      allow(credential_sources).to receive(:claude_env_value)
        .with('AWS_BEARER_TOKEN_BEDROCK').and_return(nil)
      allow(credential_sources).to receive(:claude_env_value)
        .with('AWS_DEFAULT_REGION').and_return(nil)
      allow(credential_sources).to receive(:claude_config_value)
        .with(:env).and_return({ 'MY_AWS_BEARER_TOKEN_FOR_BEDROCK' => 'tok-pattern' })

      expect(discover[:claude][:bearer_token]).to eq('tok-pattern')
      expect(discover[:claude][:bedrock_region]).to eq('us-east-2')
    end

    it 'omits :claude when neither exact key nor pattern match found' do
      allow(credential_sources).to receive(:claude_config_value).with(:env).and_return({})

      expect(discover).not_to have_key(:claude)
    end
  end

  describe 'SigV4 via ENV' do
    it 'returns :env_sigv4 when both access key and secret key are set' do
      allow(credential_sources).to receive(:env).with('AWS_ACCESS_KEY_ID').and_return('AKID123')
      allow(credential_sources).to receive(:env).with('AWS_SECRET_ACCESS_KEY').and_return('secret456')
      allow(credential_sources).to receive(:env).with('AWS_SESSION_TOKEN').and_return('session789')
      allow(credential_sources).to receive(:env).with('AWS_DEFAULT_REGION').and_return('ap-southeast-1')

      expect(discover).to include(
        env_sigv4: {
          api_key: 'AKID123',
          bedrock_access_key_id: 'AKID123',
          bedrock_secret_access_key: 'secret456',
          bedrock_session_token: 'session789',
          bedrock_region: 'ap-southeast-1',
          tier: :cloud
        }
      )
    end

    it 'omits session_token when not set' do
      allow(credential_sources).to receive(:env).with('AWS_ACCESS_KEY_ID').and_return('AKID')
      allow(credential_sources).to receive(:env).with('AWS_SECRET_ACCESS_KEY').and_return('SECRET')

      expect(discover[:env_sigv4]).not_to have_key(:bedrock_session_token)
    end

    it 'omits :env_sigv4 when access key is missing' do
      allow(credential_sources).to receive(:env).with('AWS_SECRET_ACCESS_KEY').and_return('SECRET')

      expect(discover).not_to have_key(:env_sigv4)
    end

    it 'omits :env_sigv4 when secret key is missing' do
      allow(credential_sources).to receive(:env).with('AWS_ACCESS_KEY_ID').and_return('AKID')

      expect(discover).not_to have_key(:env_sigv4)
    end
  end

  describe 'extension settings' do
    it 'returns :settings when bedrock settings exist' do
      allow(credential_sources).to receive(:setting)
        .with(:extensions, :llm, :bedrock)
        .and_return({ bedrock_region: 'us-east-1', bedrock_access_key_id: 'AKID-SETTINGS' })

      expect(discover).to include(
        settings: {
          bedrock_region: 'us-east-1',
          bedrock_access_key_id: 'AKID-SETTINGS',
          tier: :cloud
        }
      )
    end

    it 'omits :settings when setting returns nil' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock).and_return(nil)

      expect(discover).not_to have_key(:settings)
    end

    it 'omits :settings when setting returns an empty hash' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock).and_return({})

      expect(discover).not_to have_key(:settings)
    end
  end

  describe 'Identity::Broker' do
    let(:broker) do
      Module.new do
        def self.credentials_for(provider)
          return nil unless provider == :aws

          {
            access_key_id: 'AKID-BROKER',
            secret_access_key: 'SECRET-BROKER',
            session_token: 'SES-BROKER',
            region: 'us-gov-west-1'
          }
        end
      end
    end

    it 'returns :broker when Legion::Identity::Broker provides AWS creds' do
      stub_const('Legion::Identity::Broker', broker)

      expect(discover).to include(
        broker: {
          api_key: 'AKID-BROKER',
          bedrock_access_key_id: 'AKID-BROKER',
          bedrock_secret_access_key: 'SECRET-BROKER',
          bedrock_session_token: 'SES-BROKER',
          bedrock_region: 'us-gov-west-1',
          tier: :cloud
        }
      )
    end

    it 'omits :broker when Identity::Broker is not defined' do
      expect(discover).not_to have_key(:broker)
    end

    it 'omits :broker when broker returns nil credentials' do
      null_broker = Module.new { def self.credentials_for(_); end }
      stub_const('Legion::Identity::Broker', null_broker)

      expect(discover).not_to have_key(:broker)
    end
  end

  describe 'dedup' do
    it 'deduplicates bearer token credentials across sources' do
      allow(credential_sources).to receive(:env)
        .with('AWS_BEARER_TOKEN_BEDROCK').and_return('tok-same')
      allow(credential_sources).to receive(:claude_env_value)
        .with('AWS_BEARER_TOKEN_BEDROCK').and_return('tok-same')

      # env_bearer should win because it appears first
      expect(discover).to have_key(:env_bearer)
      expect(discover).not_to have_key(:claude)
    end

    it 'deduplicates SigV4 credentials via api_key' do
      allow(credential_sources).to receive(:env)
        .with('AWS_ACCESS_KEY_ID').and_return('AKID-SAME')
      allow(credential_sources).to receive(:env)
        .with('AWS_SECRET_ACCESS_KEY').and_return('SECRET')

      broker = Module.new do
        def self.credentials_for(_)
          { access_key_id: 'AKID-SAME', secret_access_key: 'SECRET' }
        end
      end
      stub_const('Legion::Identity::Broker', broker)

      # env_sigv4 should win because it appears first
      expect(discover).to have_key(:env_sigv4)
      expect(discover).not_to have_key(:broker)
    end

    it 'keeps distinct credentials from different sources' do
      allow(credential_sources).to receive(:env)
        .with('AWS_BEARER_TOKEN_BEDROCK').and_return('tok-bearer')
      allow(credential_sources).to receive(:env)
        .with('AWS_ACCESS_KEY_ID').and_return('AKID-SIGV4')
      allow(credential_sources).to receive(:env)
        .with('AWS_SECRET_ACCESS_KEY').and_return('SECRET-SIGV4')

      expect(discover.keys).to include(:env_bearer, :env_sigv4)
    end
  end

  it 'returns an empty hash when no credentials are found' do
    expect(discover).to eq({})
  end
end
