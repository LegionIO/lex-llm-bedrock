# frozen_string_literal: true

require 'spec_helper'

require 'legion/extensions/llm/bedrock/runners/discovery'

# Weight publication (R6) against the current production path:
#
#   Drafts are built identity-weighted — weight is NOT computed at draft
#   time (the old draft-time weight ownership is deleted). The shared
#   Inventory::WeightReconciler recomputes the write-time weight from LIVE
#   settings at publish (commit/activate/replace), and the published LANE
#   carries the 4-component pair.
#
# The reconciler's own sequence/dormant/retry/serialization semantics are
# lex-llm-owned and covered by lex-llm's suite; this spec pins the BEDROCK
# slice only: identity-weighted drafts from the AWS catalog summary, the
# claim-then-weight-commit order, and the configured components on the
# published lane — all through the real pipeline methods (refresh).
WEIGHT_TEST_MODEL_ID = 'anthropic.claude-test'

RSpec.describe Legion::Extensions::Llm::Bedrock::Runners::Discovery do
  let(:runner) { described_class }

  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:settings_root) { Legion::Settings[:extensions] }
  let(:root) { Legion::Settings.loader.settings }

  def east_config
    { region: 'us-east-1', bearer_token: 'tok-east', enabled: true, bedrock_stub_responses: true }
  end

  def summary
    { model_id: WEIGHT_TEST_MODEL_ID, input_modalities: %w[TEXT], output_modalities: %w[TEXT],
      response_streaming_supported: true }
  end

  def instance_key
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :bedrock, instance_id: 'east',
      physical_id: Legion::Extensions::Llm::Bedrock::InstanceIdentity.derive_physical_id(instance_cfg: east_config)
    )
  end

  # Live-settings weight scopes the WeightReconciler reads at publish:
  #   extensions.llm.bedrock.weight                             (provider)
  #   extensions.llm.bedrock.instances.east.weight              (instance)
  #   extensions.llm.bedrock.instances.east.models.<m>.weight   (model)
  #   llm.routing.tier_weights.cloud                            (tier)
  def configure_east(provider_weight: nil, instance_weight: nil, model_weight: nil, tier: 100)
    east = east_config
    east[:weight] = instance_weight unless instance_weight.nil?
    east[:models] = { WEIGHT_TEST_MODEL_ID => { weight: model_weight } } unless model_weight.nil?
    bedrock = { instances: { east: east } }
    bedrock[:weight] = provider_weight unless provider_weight.nil?
    settings_root[:llm] = { bedrock: bedrock }
    root[:llm] = { routing: { tier_weights: { cloud: tier } } }
    allow(credential_sources).to receive(:setting).with(:extensions, :llm, :bedrock).and_return(bedrock)
    bedrock
  end

  # A stub control-plane client whose catalog is the single test model —
  # keeps the real fetch/health paths offline.
  def catalog_client
    double(list_foundation_models: Struct.new(:model_summaries).new([summary]))
  end

  around do |example|
    saved_llm = root[:llm]
    saved_extensions = root[:extensions]
    example.run
  ensure
    root[:llm] = saved_llm
    root[:extensions] = saved_extensions
  end

  before do
    registry.reset!
    runner.reset_state!
    allow(credential_sources).to receive_messages(
      env: nil, claude_env_value: nil, claude_config_value: nil
    )
    hide_const('Legion::Identity::Broker')
  end

  after do
    runner.reset_state!
    registry.reset!
  end

  it 'builds identity-weighted drafts — weight is not computed at draft time' do
    configure_east(provider_weight: 110, instance_weight: 115, model_weight: 120, tier: 130)

    draft = runner.build_offering_draft(
      instance_cfg: east_config, instance_key: instance_key, model_id: WEIGHT_TEST_MODEL_ID, model_data: summary
    )

    # The draft carries the identity pair; the configured components appear
    # only after the WeightReconciler rewrites them at publish (one weight
    # owner — the draft is never pre-weighted).
    expect(draft.weight_inputs).to eq(tier: 100, provider: 100, instance: 100, model_or_offering: 100)
    expect(draft.base_weight).to eq(100_000_000)
  end

  it 'claims first, holds a malformed weight at :initializing, then publishes the corrected weight' do
    configure_east(provider_weight: false)
    allow(runner).to receive(:build_bedrock_client).and_return(catalog_client)
    allow(registry).to receive(:claim_instance).and_call_original
    allow(registry).to receive(:activate_instance_snapshot).and_call_original

    runner.refresh

    # 0.8.0 order: the instance is CLAIMED first; the malformed weight
    # (false is not an Integer >= 0) aborts the weight commit at publish,
    # leaving it claimed but :initializing — not unclaimed, not activated.
    expect(registry).to have_received(:claim_instance).once
    expect(registry).not_to have_received(:activate_instance_snapshot)
    expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:initializing)
    expect(registry.snapshot.instance(instance_key: instance_key)).to be_nil
    expect(runner.states['east'][:published]).to be(false)

    configure_east(provider_weight: 110, instance_weight: 115, model_weight: 120, tier: 130)
    runner.refresh

    expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:complete)
    expect(registry.snapshot.instance(instance_key: instance_key).availability.state).to eq(:available)
    # The PUBLISHED lane carries the exact 4-component write-time weight and
    # its product.
    lane = registry.snapshot.lanes_for(instance_key: instance_key).first
    expect(lane.weight_inputs).to eq(tier: 130, provider: 110, instance: 115, model_or_offering: 120)
    expect(lane.base_weight).to eq(197_340_000)
  end

  it 'publishes one replacement carrying the new component on the next ordinary pass (weight-only drift)' do
    configure_east(provider_weight: 100, instance_weight: 100, model_weight: 100)
    allow(runner).to receive(:build_bedrock_client).and_return(catalog_client)
    allow(registry).to receive(:replace_instance_snapshot).and_call_original

    runner.refresh
    expect(registry).not_to have_received(:replace_instance_snapshot)

    configure_east(provider_weight: 100, instance_weight: 111, model_weight: 100)
    runner.refresh

    expect(registry).to have_received(:replace_instance_snapshot).once.with(
      hash_including(
        instance_key: instance_key,
        sequence: 1,
        offerings: satisfy { |offerings| offerings.first.weight_inputs[:instance] == 111 }
      )
    )
    lane = registry.snapshot.lanes_for(instance_key: instance_key).first
    expect(lane.weight_inputs[:instance]).to eq(111)
  end

  it 'preserves zero as a disable component on the published lane' do
    configure_east(provider_weight: 0)
    allow(runner).to receive(:build_bedrock_client).and_return(catalog_client)

    runner.refresh

    lane = registry.snapshot.lanes_for(instance_key: instance_key).first
    expect(lane.weight_inputs[:provider]).to eq(0)
    expect(lane.base_weight).to eq(0)
  end
end
