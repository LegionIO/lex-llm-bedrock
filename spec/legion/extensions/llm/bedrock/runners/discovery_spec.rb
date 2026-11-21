# frozen_string_literal: true

require 'spec_helper'

require 'legion/extensions/llm/bedrock/runners/discovery'
require 'legion/extensions/llm/bedrock/actors/discovery'

# The Bedrock discovery runner (Runners::Discovery over the shared
# Discovery::Pipeline) — the write half of the inventory. The empty
# Actor::Discovery subclass fires on the discovery interval and dispatches
# `refresh` here. The pre-collapse Actor::DiscoveryRefresh surface (manual,
# @instance_states, claimable_instances) is gone: ticks are driven through
# the module's public `refresh`, and working state is read from `states`.
#
# Pipeline-internal semantics (reconcile/replace equivalence, sequence
# allocation, dormant tracking, retry) are lex-llm-owned and covered by
# lex-llm's suite; this spec pins the Bedrock slice: claimability through
# the provider catalog, the AWS control-plane fetch/health hooks, the
# 5-key display health write-back, and the actor cadence.
RSpec.describe Legion::Extensions::Llm::Bedrock::Runners::Discovery do
  let(:runner) { described_class }
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
  # The catalog and the readiness probe are the SAME control-plane call on
  # the same client.
  def make_client(healthy:, summaries: [])
    state = { healthy: healthy }
    client = Object.new
    client.define_singleton_method(:list_foundation_models) do
      raise Aws::Bedrock::Errors::ServiceError.new(Seahorse::Client::RequestContext.new, 'service unavailable') \
        unless state[:healthy]

      Struct.new(:model_summaries).new(summaries)
    end
    [client, state]
  end

  def ready_result
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'ready')
  end

  before do
    registry.reset!
    runner.reset_state!
    # Isolate from ambient AWS credential sources (env/claude/broker) — these
    # tests drive the SSOT source purely from configured settings.
    allow(credential_sources).to receive_messages(
      env: nil, claude_env_value: nil, claude_config_value: nil, setting: bedrock_settings
    )
    hide_const('Legion::Identity::Broker')
    settings_root[:llm] = { bedrock: bedrock_settings }
  end

  after do
    runner.reset_state!
    registry.reset!
  end

  describe 'claimability (no provider-family fallback identity)' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { apsoutheast: { region: 'ap-southeast-1',
                                                                                            enabled: true } })
    end

    it 'does not claim a credential-less instance' do
      runner.refresh

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
    end

    it 'derives nil (never a default-chain id) for the credential-less config' do
      expect(identity.derive_physical_id(instance_cfg: { bedrock_region: 'ap-southeast-1' })).to be_nil
    end
  end

  describe 'default instance (template-conditional skip, v2 parity)' do
    it 'never claims the unmodified template nested in settings' do
      # The unmodified synthetic template: the instances.default that
      # ProviderSettings.build always nests from Bedrock.default_settings
      # (placeholder/nil credentials).
      template_raw = Legion::Extensions::Llm::Bedrock.default_settings.dig(:instances, :default)
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { default: template_raw })
      runner.refresh

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
    end

    it 'claims and activates a configured default — "default" is an ordinary label (0.8.0)' do
      default_config = { region: 'us-east-1', bearer_token: 'tok-default', enabled: true,
                         bedrock_stub_responses: true }
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { default: default_config })
      settings_root[:llm] = { bedrock: { instances: { default: default_config } } }

      runner.refresh

      record = registry.snapshot.instance(instance_key: key_for(:default, default_config))
      expect(record.instance_key.instance_id).to eq('default')
      expect(record.availability.state).to eq(:available)
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
      runner.refresh

      on_config = { region: 'us-east-1', bearer_token: 'tok-on' }
      off_config = { region: 'us-east-1', bearer_token: 'tok-off' }
      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key_for(:on, on_config)).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key_for(:off, off_config))).to be_nil
    end
  end

  describe 'initial claim and activation' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      # B16: the display writer only touches operator-owned settings entries
      # — the operator's entry exists in the settings tree here.
      settings_root[:llm] = { bedrock: { instances: { east: east_config } } }
    end

    it 'claims, probes, and activates a configured instance' do
      runner.refresh

      snapshot = registry.snapshot
      instance_key = key_for(:east, east_config)
      expect(snapshot.instance(instance_key: instance_key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: instance_key).state).to eq(:complete)
    end

    it 'publishes the config NAME as instance_id and the derived id as the secondary physical_id' do
      runner.refresh

      record = registry.snapshot.instance(instance_key: key_for(:east, east_config))
      expect(record.instance_key.instance_id).to eq('east')
      physical = "us-east-1/bearer:#{Digest::SHA256.hexdigest('tok-east')[0, 8]}"
      expect(record.instance_key.physical_id).to eq(physical)
    end

    it 'writes the 5-key display health hash after the registry commit' do
      runner.refresh

      health = health_for(:east)
      expect(health).to include(
        state: :available,
        reason: 'startup readiness succeeded',
        last_probe_outcome: :success,
        source: :startup_readiness
      )
      expect(health[:observed_at]).to be_a(String)
      # V14: the pre-SSOT circuit dial (circuit_state/denied/available/
      # adjustment) is gone from the settings tree.
      expect(health).not_to have_key(:circuit_state)
      expect(health).not_to have_key(:denied)
      expect(health).not_to have_key(:adjustment)
      expect(settings_root.dig(:llm, :bedrock, :instances, :east, :capabilities)).to eq([])
    end
  end

  describe 'startup publication validation' do
    it 'claims first, holds a malformed weight at :initializing, and activates once after correction' do
      bedrock_settings.merge!(weight: false, instances: { east: east_config })
      settings_root[:llm] = { bedrock: bedrock_settings }
      summary = {
        model_id: 'anthropic.claude-test',
        input_modalities: %w[TEXT],
        output_modalities: %w[TEXT],
        response_streaming_supported: true
      }
      client = double(list_foundation_models: Struct.new(:model_summaries).new([summary]))
      allow(runner).to receive(:build_bedrock_client).and_return(client)
      allow(registry).to receive(:claim_instance).and_call_original
      allow(registry).to receive(:activate_instance_snapshot).and_call_original
      instance_key = key_for(:east, east_config)

      runner.refresh

      # 0.8.0 order: the instance is CLAIMED first; the malformed weight
      # aborts the weight commit at publish, leaving it claimed but
      # :initializing (not unclaimed, not activated).
      expect(registry).to have_received(:claim_instance).once
      expect(registry).not_to have_received(:activate_instance_snapshot)
      expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: instance_key)).to be_nil
      expect(runner.states['east'][:published]).to be(false)

      bedrock_settings[:weight] = 100
      runner.refresh

      state = runner.states.fetch('east')
      expect(registry).to have_received(:activate_instance_snapshot).once
      expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: instance_key).availability.state).to eq(:available)
      expect(state).to include(published: true, sequence: 0)
      expect(state[:publisher_token]).not_to be_nil
    end
  end

  # B8: a failed catalog observation is not a catalog fact. The replace path
  # keeps the last published snapshot (the old [] conflation wiped every
  # lane of an active instance for up to one discovery interval); a
  # genuinely empty catalog arrives as [] and still publishes.
  describe 'failed observation retention (B8)' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config } } }
      allow(registry).to receive(:replace_instance_snapshot).and_call_original
    end

    it 'keeps the published snapshot when a catalog fetch fails on an active instance' do
      summary = { model_id: 'anthropic.claude-a', input_modalities: %w[TEXT], output_modalities: %w[TEXT],
                  response_streaming_supported: true }
      client, state = make_client(healthy: true, summaries: [summary])
      allow(runner).to receive(:build_bedrock_client).and_return(client)

      runner.refresh
      instance_key = key_for(:east, east_config)
      expect(registry.snapshot.lanes_for(instance_key: instance_key)).not_to be_empty

      state[:healthy] = false
      runner.refresh

      expect(registry).not_to have_received(:replace_instance_snapshot)
      # The last published snapshot survives the failed observation — the
      # failed fetch is "no observation", not an empty catalog.
      expect(registry.snapshot.lanes_for(instance_key: instance_key)).not_to be_empty
    end

    it 'stays initializing when the claim-time fetch fails, then recovers on a passing tick' do
      client, state = make_client(healthy: false)
      allow(runner).to receive(:build_bedrock_client).and_return(client)

      runner.refresh

      instance_key = key_for(:east, east_config)
      expect(registry.snapshot.instance(instance_key: instance_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:initializing)

      state[:healthy] = true
      runner.refresh

      # A genuinely observed (empty) catalog still activates.
      expect(registry.snapshot.instance(instance_key: instance_key).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:complete)
    end
  end

  # B14: the ReadinessResult contract carries no exception — a bounded class
  # name, never e.message.
  describe 'readiness reason hygiene (B14)' do
    it 'carries the exception class name, not the message, in readiness reason' do
      # The catalog and the readiness probe share one control-plane call on
      # one client: first client builds the catalog, the second (failing)
      # client serves the readiness probe.
      catalog_client, _catalog = make_client(healthy: true)
      health_client, _health = make_client(healthy: false)
      allow(runner).to receive(:build_bedrock_client).and_return(catalog_client, health_client)
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })

      runner.refresh

      status = registry.snapshot.publication_status(instance_key: key_for(:east, east_config))
      expect(status.state).to eq(:initializing)
      expect(status.last_error).to include('Aws::Bedrock::Errors::ServiceError')
      expect(status.last_error).not_to include('service unavailable')
    end
  end

  # B16: the display writer only touches operator-owned settings entries —
  # a source-named instance (env credential, no settings entry) gets no
  # synthetic settings entry.
  describe 'display writer ownership (B16)' do
    it 'does not create a settings entry for a source-named instance' do
      allow(credential_sources).to receive(:env).with('AWS_BEARER_TOKEN_BEDROCK').and_return('tok-env')
      allow(credential_sources).to receive(:env).with('AWS_DEFAULT_REGION').and_return('us-east-1')
      client, _state = make_client(healthy: true)
      settings_root[:llm] = { bedrock: {} }

      allow(runner).to receive(:build_bedrock_client).and_return(client)
      runner.refresh

      expect(settings_root.dig(:llm, :bedrock, :instances, :env_bearer)).to be_nil
    end
  end

  describe 'recovery after an initial readiness failure (D4)' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      # B16: operator-owned settings entry (the display writer's guard).
      settings_root[:llm] = { bedrock: { instances: { east: east_config } } }
    end

    it 'stays initializing while unhealthy, then re-activates on a later passing probe' do
      not_ready = Legion::Extensions::Llm::Inventory::ReadinessResult.new(
        ready: false, reason: 'Bedrock ListFoundationModels failed: Aws::Bedrock::Errors::ServiceError',
        metadata: { error_class: 'Aws::Bedrock::Errors::ServiceError' }
      )
      allow(runner).to receive(:check_health).and_return(not_ready)

      runner.refresh

      instance_key = key_for(:east, east_config)
      expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: instance_key)).to be_nil
      # The 5-key health shape projects an :initializing instance as
      # :initializing — the old half_open mislabel is gone.
      expect(health_for(:east)).to include(state: :initializing, last_probe_outcome: :failure)
      expect(health_for(:east)[:reason]).not_to include('service unavailable')

      allow(runner).to receive(:check_health).and_return(ready_result)
      runner.refresh

      expect(registry.snapshot.instance(instance_key: instance_key).availability.state).to eq(:available)
      expect(health_for(:east)).to include(state: :available, last_probe_outcome: :success)
    end
  end

  describe 'tick reconciliation' do
    it 'claims an instance configured after boot on a later tick' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config } } }

      runner.refresh
      expect(registry.snapshot.publication_status(instance_key: key_for(:west, west_config))).to be_nil

      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config, west: west_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config, west: west_config } } }
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key_for(:west, west_config)).availability.state).to eq(:available)
    end

    it 'removes an instance whose configuration disappeared and clears its display health' do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config, west: west_config })
      settings_root[:llm] = { bedrock: { instances: { east: east_config, west: west_config } } }

      runner.refresh
      expect(registry.snapshot.instance(instance_key: key_for(:west, west_config))).not_to be_nil
      expect(health_for(:west)).not_to be_nil

      # Only the discovery source loses west — the operator's settings entry
      # stays, so the display writer's clear path is exercised.
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      runner.refresh

      expect(registry.snapshot.publication_status(instance_key: key_for(:west, west_config))).to be_nil
      expect(health_for(:west)).to be_nil
    end
  end

  describe 'shutdown' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock)
                                                    .and_return(instances: { east: east_config })
      # B16: operator-owned settings entry (the display writer's guard).
      settings_root[:llm] = { bedrock: { instances: { east: east_config } } }
    end

    it 'removes every claimed instance and clears the settings health' do
      runner.refresh
      expect(registry.snapshot.each_publication_status.to_a).not_to be_empty
      expect(health_for(:east)).not_to be_nil

      runner.remove_all_instances

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(health_for(:east)).to be_nil
    end
  end

  # D9: the empty Actor::Discovery subclass inherits the base actor's
  # interval resolution (instances.default.discovery_interval →
  # discovery.interval_seconds → 300; never nil).
  describe 'discovery cadence (D9)' do
    it 'reads the registered discovery interval' do
      settings_root[:llm] = { bedrock: { discovery: { interval_seconds: 42 } } }

      actor = Legion::Extensions::Llm::Bedrock::Actor::Discovery.new
      expect(actor.time).to eq(42)
    end

    it 'falls back to the registered default (never nil) when the settings tree has no discovery section' do
      actor = Legion::Extensions::Llm::Bedrock::Actor::Discovery.new
      expect(actor.time).to eq(300)
    end

    it 'has no dead self.every_seconds' do
      expect(Legion::Extensions::Llm::Bedrock::Actor::Discovery.respond_to?(:every_seconds)).to be(false)
    end
  end
end
