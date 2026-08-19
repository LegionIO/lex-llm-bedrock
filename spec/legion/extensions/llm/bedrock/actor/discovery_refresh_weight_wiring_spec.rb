# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/actors/discovery_refresh'
require 'legion/extensions/llm/inventory/weight_reconciler'

RSpec.describe Legion::Extensions::Llm::Bedrock::Actor::DiscoveryRefresh do
  let(:weight_reconciler) { Legion::Extensions::Llm::Inventory::WeightReconciler }
  let(:instance_key) do
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :bedrock, instance_id: 'east', physical_id: 'us-east-1/test'
    )
  end
  let(:actor) { described_class.new }
  let(:publisher) do
    snapshot = instance_double(Legion::Extensions::Llm::Inventory::Snapshot)
    availability = instance_double(Legion::Extensions::Llm::Inventory::AvailabilityFact, state: :available)
    allow(snapshot).to receive(:instance).and_return(double(availability: availability))
    instance_double(
      Legion::Extensions::Llm::Inventory::Publisher,
      snapshot: snapshot,
      replace_instance_snapshot: nil,
      activate_instance_snapshot: nil,
      remove_instance: nil,
      readiness_failed: nil
    )
  end
  let(:settings_root) { Legion::Settings.loader.settings }

  def base_draft(actor:, key: instance_key, model: 'anthropic.claude-test')
    actor.send(
      :build_offering_draft,
      model_id: model,
      summary: {
        input_modalities: %w[text], output_modalities: %w[text],
        response_streaming_supported: true
      },
      instance_cfg: { tier: :cloud },
      instance_key: key
    )
  end

  def state_for(draft:, published: true)
    {
      name: :east,
      instance_key: instance_key,
      instance_cfg: { tier: :cloud },
      publisher_token: Object.new,
      sequence: 0,
      offerings: [draft].freeze,
      published: published,
      last_probe_outcome: nil
    }
  end

  def configure_weights(provider: 100, instance: 100, model: 100, tier: 100)
    settings_root[:extensions] ||= {}
    settings_root[:extensions][:llm] = {
      bedrock: {
        weight: provider,
        instances: { east: { weight: instance, models: { 'anthropic.claude-test' => { weight: model } } } }
      }
    }
    settings_root[:llm] = { routing: { tier_weights: { cloud: tier } } }
  end

  before do
    configure_weights
    actor.instance_variable_set(:@publisher, publisher)
  end

  after { actor.shutdown }

  it 'constructs drafts with the exact four weight components and their product' do
    configure_weights(provider: 110, instance: 115, model: 120, tier: 130)

    draft = base_draft(actor: actor)

    expect(draft.weight_inputs).to eq(tier: 130, provider: 110, instance: 115, model_or_offering: 120)
    expect(draft.base_weight).to eq(197_340_000)
  end

  it 'publishes one replacement for weight-only drift on the next ordinary refresh' do
    original_config = { tier: :cloud, weight: 100, models: { 'anthropic.claude-test' => { weight: 100 } } }
    draft = base_draft(actor: actor)
    state = state_for(draft: draft)
    state[:instance_cfg] = original_config
    actor.instance_variable_set(:@instance_states, 'east' => state)
    allow(actor).to receive_messages(discover_offerings_for_instance: [draft],
                                     claimable_instances: { east: original_config.merge(weight: 111) })
    allow(actor).to receive(:run_cadence_probe)
    configure_weights(instance: 111)

    actor.send(:tick_refresh)

    expect(publisher).to have_received(:replace_instance_snapshot).once.with(
      hash_including(instance_id: 'east', offerings: satisfy(&:frozen?), sequence: 1)
    )
    expect(state[:offerings].first.weight_inputs[:instance]).to eq(111)
    expect(state[:sequence]).to eq(1)
  end

  it 'does not publish when a settings change leaves the weight pair unchanged' do
    draft = base_draft(actor: actor)
    state = state_for(draft: draft)
    actor.instance_variable_set(:@instance_states, 'east' => state)
    allow(actor).to receive(:discover_offerings_for_instance).and_return([draft])
    settings_root[:extensions][:llm][:unrelated] = { enabled: true }

    actor.send(:replace_offerings_if_changed, instance_id: 'east', state: state)

    expect(publisher).not_to have_received(:replace_instance_snapshot)
    expect(state[:sequence]).to eq(0)
  end

  it 'preserves zero as a disable component and rejects false' do
    configure_weights(provider: 0)
    expect(base_draft(actor: actor).weight_inputs[:provider]).to eq(0)

    configure_weights(provider: false)
    expect { base_draft(actor: actor) }.to raise_error(ArgumentError, /Integer >= 0/)
  end

  it 'logs each dormant configured lane key once until it appears and disappears again' do
    configure_weights(provider: 100)
    states = {}
    actor.instance_variable_set(:@instance_states, states)
    key = %i[bedrock provider]
    logger = instance_double(Logger, info: nil)
    allow(actor).to receive(:log).and_return(logger)

    actor.send(:observe_dormant_weights)
    actor.send(:observe_dormant_weights)
    draft = base_draft(actor: actor)
    states['east'] = state_for(draft: draft)
    actor.send(:observe_dormant_weights)
    states.clear
    actor.send(:observe_dormant_weights)

    expect(logger).to have_received(:info).with(
      "[llm][bedrock] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
    ).twice
  end

  it 'keeps sequence stable across ten unchanged ordinary refreshes' do
    draft = base_draft(actor: actor)
    state = state_for(draft: draft)
    actor.instance_variable_set(:@instance_states, 'east' => state)
    allow(actor).to receive(:discover_offerings_for_instance).and_return([draft])

    10.times { actor.send(:replace_offerings_if_changed, instance_id: 'east', state: state) }

    expect(publisher).not_to have_received(:replace_instance_snapshot)
    expect(state[:sequence]).to eq(0)
  end

  it 'uses no Legion::Settings lifecycle or callback API' do
    source = File.read(described_class.instance_method(:manual).source_location.first)

    expect(source).not_to match(/Legion::Settings\.(?:on_reload|reload!|reset!|off_reload)/)
  end

  it 'serializes interleaved ordinary refreshes without duplicate sequences' do
    draft = base_draft(actor: actor)
    state = state_for(draft: draft)
    actor.instance_variable_set(:@instance_states, 'east' => state)
    configure_weights(provider: 111)
    allow(actor).to receive(:discover_offerings_for_instance).and_return([draft])
    published_sequences = Queue.new
    allow(publisher).to receive(:replace_instance_snapshot) do |sequence:, **|
      published_sequences << sequence
    end

    threads = Array.new(2) do
      Thread.new { actor.send(:replace_offerings_if_changed, instance_id: 'east', state: state) }
    end
    threads.each(&:join)

    expect(published_sequences.size).to eq(1)
    expect(published_sequences.pop).to eq(1)
    expect(state[:sequence]).to eq(1)
    expect(state[:offerings].first.weight_inputs[:provider]).to eq(111)
  end

  it 'leaves cache and sequence unchanged when replacement raises, then retries' do
    draft = base_draft(actor: actor)
    state = state_for(draft: draft)
    actor.instance_variable_set(:@instance_states, 'east' => state)
    configure_weights(provider: 111)
    allow(actor).to receive(:discover_offerings_for_instance).and_return([draft])
    attempts = 0
    allow(publisher).to receive(:replace_instance_snapshot) do
      attempts += 1
      raise 'publish failed' if attempts == 1
    end

    expect do
      actor.send(:replace_offerings_if_changed, instance_id: 'east', state: state)
    end.to raise_error(RuntimeError, 'publish failed')
    expect(state.values_at(:sequence, :offerings)).to eq([0, [draft]])

    actor.send(:replace_offerings_if_changed, instance_id: 'east', state: state)
    expect(state[:sequence]).to eq(1)
    expect(state[:offerings].first.weight_inputs[:provider]).to eq(111)
  end

  it 'rebuilds from current settings at initial activation time' do
    draft = base_draft(actor: actor)
    publisher_token = Object.new
    probe_token = Object.new
    allow(publisher).to receive_messages(
      claim_instance: publisher_token,
      readiness_probe_started: probe_token
    )
    allow(actor).to receive(:discover_offerings_for_instance).and_return([draft])
    actor.instance_variable_set(:@instance_states, {})
    allow(actor).to receive(:check_health) do
      tracked = actor.instance_variable_get(:@instance_states).fetch('east')
      expect(tracked[:published]).to be(false)
      configure_weights(provider: 123)
      Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'ready')
    end

    actor.send(
      :claim_and_activate_instance,
      name: :east,
      instance_cfg: { tier: :cloud, region: 'us-east-1', bearer_token: 'test-token' }
    )

    state = actor.instance_variable_get(:@instance_states).fetch('east')

    expect(publisher).to have_received(:activate_instance_snapshot).with(
      hash_including(offerings: satisfy { |offerings| offerings.first.weight_inputs[:provider] == 123 })
    )
    expect(state[:offerings].first.weight_inputs[:provider]).to eq(123)
    expect(state[:published]).to be(true)
  end

  it 'updates an unpublished cache without replacing or counting it as published' do
    draft = base_draft(actor: actor)
    state = state_for(draft: draft, published: false)
    actor.instance_variable_set(:@instance_states, 'east' => state)
    configure_weights(provider: 111)
    allow(actor).to receive(:discover_offerings_for_instance).and_return([draft])

    actor.send(:replace_offerings_if_changed, instance_id: 'east', state: state)

    expect(publisher).not_to have_received(:replace_instance_snapshot)
    expect(publisher).not_to have_received(:activate_instance_snapshot)
    expect(state[:offerings].first.weight_inputs[:provider]).to eq(111)
    expect(weight_reconciler.send(:published_weight_keys, provider_family: :bedrock,
                                                          states: { east: state })).to be_empty
  end

  it 'does not resurrect a state removed while readiness is in flight' do
    draft = base_draft(actor: actor)
    state = state_for(draft: draft, published: false)
    actor.instance_variable_set(:@instance_states, 'east' => state)
    actor.send(:remove_instance_state, instance_id: 'east')

    activated = actor.send(
      :activate_tracked_snapshot,
      instance_id: 'east', state: state, probe_token: Object.new
    )

    expect(activated).to be(false)
    expect(publisher).not_to have_received(:activate_instance_snapshot)
  end

  it 'leaves activation state unchanged on publisher failure and permits retry' do
    draft = base_draft(actor: actor)
    state = state_for(draft: draft, published: false)
    actor.instance_variable_set(:@instance_states, 'east' => state)
    attempts = 0
    allow(publisher).to receive(:activate_instance_snapshot) do
      attempts += 1
      raise 'activation failed' if attempts == 1
    end

    expect do
      actor.send(:activate_tracked_snapshot, instance_id: 'east', state: state, probe_token: Object.new)
    end.to raise_error(RuntimeError, 'activation failed')
    expect(state.values_at(:sequence, :offerings, :published)).to eq([0, [draft], false])

    expect do
      actor.send(:activate_tracked_snapshot, instance_id: 'east', state: state, probe_token: Object.new)
    end.not_to raise_error
    expect(state[:published]).to be(true)
  end
end
