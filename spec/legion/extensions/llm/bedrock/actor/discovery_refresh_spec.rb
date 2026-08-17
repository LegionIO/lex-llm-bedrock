# frozen_string_literal: true

require 'spec_helper'

require 'legion/extensions/llm/bedrock/actors/discovery_refresh'

RSpec.describe Legion::Extensions::Llm::Bedrock::Actor::DiscoveryRefresh do
  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:bedrock_settings) { {} }
  let(:settings_root) { Legion::Settings[:extensions] }

  def identity
    Legion::Extensions::Llm::Bedrock::InstanceIdentity
  end

  # Name-based identity: instance_id is the operator's CONFIG NAME,
  # physical_id is the secondary derived region/credential id.
  def key_for(name, config)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :bedrock, instance_id: name.to_s,
      physical_id: identity.derive_physical_id(instance_cfg: config)
    )
  end

  def health_for(name)
    settings_root.dig(:llm, :bedrock, :instances, name, :health)
  end

  def east_config(**overrides)
    { region: 'us-east-1', bearer_token: 'tok-east', enabled: true, bedrock_stub_responses: true }.merge(overrides)
  end

  def west_config(**overrides)
    { region: 'us-west-2', bearer_token: 'tok-west', enabled: true, bedrock_stub_responses: true }.merge(overrides)
  end

  # A fake AWS control-plane client whose health can be flipped per test.
  def make_client(healthy:)
    state = { healthy: healthy }
    client = Object.new
    client.define_singleton_method(:list_foundation_models) do
      raise Aws::Bedrock::Errors::ServiceError.new(Seahorse::Client::RequestContext.new, 'service unavailable') \
        unless state[:healthy]

      Struct.new(:model_summaries).new([])
    end
    [client, state]
  end

  before do
    registry.reset!
    # Isolate from ambient AWS credential sources (env/claude/broker) — these
    # tests drive the SSOT source purely from configured settings.
    allow(credential_sources).to receive_messages(
      env: nil, claude_env_value: nil, claude_config_value: nil, setting: bedrock_settings
    )
    hide_const('Legion::Identity::Broker')
    settings_root[:llm] = { bedrock: bedrock_settings }
  end

  after { registry.reset! }

  describe 'claimability (no provider-family fallback identity)' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { apsoutheast: { region: 'ap-southeast-1',
                                                                                            enabled: true } })
    end

    it 'does not claim a credential-less instance' do
      actor = described_class.new
      actor.manual

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      actor.shutdown
    end

    it 'derives nil (never a default-chain id) for the credential-less config' do
      expect(identity.derive_physical_id(instance_cfg: { bedrock_region: 'ap-southeast-1' })).to be_nil
    end
  end

  describe 'reserved name (default)' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { default: east_config })
    end

    it 'never claims a config named default (the reserved InstanceKey identity)' do
      actor = described_class.new
      actor.manual

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      actor.shutdown
    end
  end

  describe 'enabled: false is not claimable' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock).and_return(
        instances: {
          off: { region: 'us-east-1', bearer_token: 'tok-off', enabled: false },
          on: east_config(bearer_token: 'tok-on')
        }
      )
    end

    it 'skips the disabled instance and claims the enabled one' do
      actor = described_class.new
      actor.manual

      on_config = { region: 'us-east-1', bearer_token: 'tok-on' }
      off_config = { region: 'us-east-1', bearer_token: 'tok-off' }
      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key_for(:on, on_config)).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key_for(:off, off_config))).to be_nil
      actor.shutdown
    end
  end

  describe 'initial claim and activation' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
    end

    it 'claims, probes, and activates a configured instance' do
      actor = described_class.new
      actor.manual

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key_for(:east, east_config)).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key_for(:east, east_config)).state).to eq(:complete)
      actor.shutdown
    end

    it 'publishes the config NAME as instance_id and the derived id as the secondary physical_id' do
      actor = described_class.new
      actor.manual

      record = registry.snapshot.instance(instance_key: key_for(:east, east_config))
      expect(record.instance_key.instance_id).to eq('east')
      physical = "us-east-1/bearer:#{Digest::SHA256.hexdigest('tok-east')[0, 8]}"
      expect(record.instance_key.physical_id).to eq(physical)
      actor.shutdown
    end

    it 'writes the settings health hash (legacy 4-key shape + display keys) after the registry commit' do
      actor = described_class.new
      actor.manual

      health = health_for(:east)
      expect(health).not_to be_nil
      expect(health[:circuit_state]).to eq(:closed)
      expect(health[:denied]).to be(false)
      expect(health[:available]).to be(true)
      expect(health[:adjustment]).to eq(0)
      expect(health[:last_probe_outcome]).to eq(:success)
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(String)
      expect(health[:source]).to eq('bedrock_ssot_actor')
      expect(settings_root.dig(:llm, :bedrock, :instances, :east, :capabilities)).to eq([])
      actor.shutdown
    end
  end

  describe 'recovery after an initial readiness failure (D4)' do
    # No stub_responses here — the fake client in the test drives readiness.
    let(:unstubbed_east) { east_config(bedrock_stub_responses: nil) }

    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: unstubbed_east })
    end

    it 'stays initializing while unhealthy, then re-activates on a later passing probe' do
      actor = described_class.new
      client, state = make_client(healthy: false)
      allow(actor).to receive(:build_bedrock_client).and_return(client)

      actor.manual
      expect(registry.snapshot.publication_status(instance_key: key_for(:east, unstubbed_east)).state)
        .to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key_for(:east, unstubbed_east))).to be_nil
      expect(health_for(:east)[:circuit_state]).to eq(:half_open)
      expect(health_for(:east)[:last_probe_outcome]).to eq(:failure)

      state[:healthy] = true
      actor.manual

      expect(registry.snapshot.instance(instance_key: key_for(:east, unstubbed_east)).availability.state)
        .to eq(:available)
      expect(health_for(:east)[:circuit_state]).to eq(:closed)
      expect(health_for(:east)[:available]).to be(true)
      expect(health_for(:east)[:last_probe_outcome]).to eq(:success)
      actor.shutdown
    end
  end

  describe 'tick reconciliation' do
    it 'claims an instance configured after boot on a later tick' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config } } }

      actor = described_class.new
      actor.manual
      expect(registry.snapshot.publication_status(instance_key: key_for(:west, west_config))).to be_nil

      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config, west: west_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config, west: west_config } } }
      actor.manual

      expect(registry.snapshot.instance(instance_key: key_for(:west, west_config)).availability.state).to eq(:available)
      actor.shutdown
    end

    it 'removes an instance whose configuration disappeared' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config, west: west_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config, west: west_config } } }

      actor = described_class.new
      actor.manual
      expect(registry.snapshot.instance(instance_key: key_for(:west, west_config))).not_to be_nil

      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config } } }
      actor.manual

      expect(registry.snapshot.publication_status(instance_key: key_for(:west, west_config))).to be_nil
      expect(health_for(:west)).to be_nil
      actor.shutdown
    end
  end

  describe 'shutdown' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
    end

    it 'removes every claimed instance and clears the settings health' do
      actor = described_class.new
      actor.manual
      expect(registry.snapshot.each_publication_status.to_a).not_to be_empty
      expect(health_for(:east)).not_to be_nil

      actor.shutdown

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(health_for(:east)).to be_nil
    end
  end

  describe 'discovery cadence (D9)' do
    it 'reads the registered discovery interval, never nil' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(discovery: { interval_seconds: 42 })
      settings_root[:llm] = { bedrock: { discovery: { interval_seconds: 42 } } }

      actor = described_class.new
      expect(actor.time).to eq(42)
      actor.shutdown
    end

    it 'falls back to the registered default when the settings tree has no discovery section' do
      actor = described_class.new
      expect(actor.time).to eq(described_class::DEFAULT_DISCOVERY_INTERVAL_SECONDS)
      actor.shutdown
    end

    it 'has no dead self.every_seconds' do
      expect(described_class.respond_to?(:every_seconds)).to be(false)
    end
  end
end
