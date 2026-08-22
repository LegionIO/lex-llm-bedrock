# frozen_string_literal: true

require 'spec_helper'
require 'digest'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# Production callable and production discovery runner. The actor file loads
# via the spec_helper actor-runtime stand-ins (the LegionIO platform is not a
# gem dependency); the harness delegates identity derivation, draft building,
# and safe readiness to the PRODUCTION runner code paths instead of
# duplicating them (a duplicated builder would drift from the runner
# silently).
require 'legion/extensions/llm/bedrock/helpers/callable'
require 'legion/extensions/llm/bedrock/runners/discovery'

# Harness class for Bedrock SSOT v3 conformance testing.
class BedrockSsotHarness
  # bedrock_stub_responses keeps the production callable's and the runner's
  # AWS SDK clients fully offline: the exact fleet dispatch test drives a real
  # Helpers::Callable -> Bedrock::Provider -> stubbed Converse round-trip,
  # and safe_readiness drives the runner's real check_health against stubs.
  #
  # Instance identity is the operator's CONFIG NAME (the key the router looks
  # up in instances.<name>); the derived region/credential id is the secondary
  # physical id (dedup/diagnostics only).
  NAMED_INSTANCE_CONFIGS = {
    us_prod: {
      bedrock_region: 'us-east-1',
      bedrock_access_key_id: 'AKIAIOSFODNN7EXAMPLE1',
      bedrock_secret_access_key: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY1',
      tier: :cloud,
      bedrock_stub_responses: true
    }.freeze,
    eu_prod: {
      bedrock_region: 'eu-west-1',
      bearer_token: 'test-bearer-token-alpha',
      tier: :cloud,
      bedrock_stub_responses: true
    }.freeze
  }.freeze

  MODEL_ID = 'anthropic.claude-sonnet-4-20250514-v1:0'

  def provider_family = :bedrock
  def instance_configs = NAMED_INSTANCE_CONFIGS.values

  # The production discovery runner module — stateless, no .new. Its public
  # builders are the single source of draft/evidence construction; the
  # harness only supplies test data (the model summary).
  def ssot_runner
    Legion::Extensions::Llm::Bedrock::Runners::Discovery
  end

  # The operator's CONFIG NAME — the InstanceKey.instance_id the router keys
  # settings lookups by. Matched on the config minus :tier because the draft
  # path merges a (possibly overridden) tier into the config copy.
  def instance_id(instance_config:)
    base = instance_config.except(:tier)
    NAMED_INSTANCE_CONFIGS.find { |_name, stored| stored.except(:tier) == base }&.first&.to_s
  end

  # Delegate to the production physical-id derivation — one source, no drift.
  # The secondary InstanceKey.physical_id (dedup/diagnostics only).
  def physical_id(instance_config:)
    Legion::Extensions::Llm::Bedrock::InstanceIdentity.derive_physical_id(instance_cfg: instance_config)
  end

  # The PRODUCTION callable — it implements the fleet dispatch operations by
  # delegating to a per-instance Bedrock::Provider.
  def build_callable(instance_config:)
    Legion::Extensions::Llm::Bedrock::Helpers::Callable.new(
      instance_cfg: instance_config, logger: Logger.new(File::NULL)
    )
  end

  # Production draft path: the runner's public build_offering_draft
  # (operation evidence, capability evidence, context window, quota domains,
  # metadata). (The kit also passes callable: — accepted and ignored; the
  # production draft path does not consult it.)
  def build_offering_drafts(tier: :cloud, instance_config: nil, **)
    config = (instance_config || instance_configs.first).merge(tier: tier)
    [ssot_runner.build_offering_draft(
      instance_cfg: config, instance_key: instance_key_for(config),
      model_id: MODEL_ID, model_data: model_summary
    )]
  end

  # Production readiness path: the runner's own check_health (a stubbed
  # ListFoundationModels control-plane call — safe in any environment).
  def safe_readiness(instance_config:, **)
    ssot_runner.check_health(instance_cfg: instance_config)
  end

  def inference_call_count(callable:)
    callable.dispatch_count
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    callable.normalize_dispatch_error(error: error)
  end

  def instance_unavailable_error
    # Only ServiceUnavailableException from AWS SDK qualifies as instance_unavailable
    Aws::BedrockRuntime::Errors::ServiceUnavailableException.new(
      Seahorse::Client::RequestContext.new,
      'Service Unavailable'
    )
  end

  def overloaded_error
    # A generic 503 service error (not explicitly ServiceUnavailableException)
    # is classified as overloaded, not instance_unavailable
    error = Aws::BedrockRuntime::Errors::ServiceError.new(
      Seahorse::Client::RequestContext.new,
      'Service overloaded'
    )
    allow_status(error: error, status: 503)
    error
  end

  def model_not_ready_error
    Aws::BedrockRuntime::Errors::ModelNotReadyException.new(
      Seahorse::Client::RequestContext.new,
      'Model is not ready'
    )
  end

  private

  def allow_status(error:, status:)
    error.define_singleton_method(:http_status_code) { status }
  end

  # Test data only: a ListFoundationModels-style model summary fed to the
  # PRODUCTION build_offering_draft. The evidence/draft construction itself is
  # the actor's, not the harness's.
  def model_summary
    { input_modalities: %w[text], output_modalities: %w[text], response_streaming_supported: true }
  end

  def instance_key_for(config)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: provider_family,
      instance_id: instance_id(instance_config: config),
      physical_id: physical_id(instance_config: config)
    )
  end
end

RSpec.describe Legion::Extensions::Llm::Bedrock do
  let(:ssot_harness) { BedrockSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # ─── Bedrock-specific physical-id derivation (production code) ────────────
  # instance_id is the operator's CONFIG NAME (supplied by the harness); the
  # derived region/credential id is the SECONDARY physical id only.

  describe 'instance physical-id derivation' do
    it 'derives physical_id as region/ak:fingerprint with access key' do
      config = { bedrock_region: 'us-east-1', bedrock_access_key_id: 'AKIAIOSFODNN7EXAMPLE1' }
      fingerprint = Digest::SHA256.hexdigest('AKIAIOSFODNN7EXAMPLE1')[0, 8]
      expect(ssot_harness.physical_id(instance_config: config)).to eq("us-east-1/ak:#{fingerprint}")
    end

    it 'derives physical_id as region/bearer:fingerprint with bearer token' do
      config = { bedrock_region: 'eu-west-1', bearer_token: 'test-bearer-token-alpha' }
      fingerprint = Digest::SHA256.hexdigest('test-bearer-token-alpha')[0, 8]
      expect(ssot_harness.physical_id(instance_config: config)).to eq("eu-west-1/bearer:#{fingerprint}")
    end

    it 'derives physical_id as region/profile:name with profile' do
      config = { bedrock_region: 'us-west-2', bedrock_profile: 'production' }
      expect(ssot_harness.physical_id(instance_config: config)).to eq('us-west-2/profile:production')
    end

    it 'derives NO physical id for a credential-less config (no provider-family fallback)' do
      config = { bedrock_region: 'ap-southeast-1' }
      expect(ssot_harness.physical_id(instance_config: config)).to be_nil
    end

    it 'publishes distinct config-name identities AND distinct physical ids for the two instances' do
      names = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(names.uniq.size).to eq(2)
      physicals = ssot_harness.instance_configs.map { |cfg| ssot_harness.physical_id(instance_config: cfg) }
      expect(physicals.uniq.size).to eq(2)
    end

    it 'reproduces the same name identity and physical id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      name_a = ssot_harness.instance_id(instance_config: config)
      name_b = ssot_harness.instance_id(instance_config: config)
      expect(name_a).to eq(name_b)
      physical_a = ssot_harness.physical_id(instance_config: config)
      physical_b = ssot_harness.physical_id(instance_config: config)
      expect(physical_a).to eq(physical_b)
    end
  end

  # ─── Two regions with same model = separate lanes ──────────────────────────

  describe 'two Bedrock instances serving the same model' do
    def bring_up_instance(config, tier: :cloud)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
      instance_id = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: instance_id, physical_id: physical_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(
        instance_id: instance_id, physical_id: physical_id, callable: callable, probe_request_handle: coordinator
      )
      probe = publisher.readiness_probe_started(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token
      )
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token,
        offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_run = bring_up_instance(config)
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      registry.reset!
      second_run = bring_up_instance(config)
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      # 0.8.0: there is no separate offering id — the offering IS the lane,
      # keyed by the 5 tuple.
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # ─── Tier change: the 5-tuple fact ─────────────────────────────────────────
  # The lane id is `tier:provider_family:instance_id:type:model` — the tier
  # IS an identity member (D2: an offering IS the 5-tuple lane). A tier
  # change therefore republishes the lane under the new tier tuple; the
  # model and instance identity it preserves are the remaining members.

  describe 'tier change and identity preservation' do
    def bring_up_with_tier(config, tier:)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
      instance_id = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: instance_id, physical_id: physical_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(
        instance_id: instance_id, physical_id: physical_id, callable: callable, probe_request_handle: coordinator
      )
      probe = publisher.readiness_probe_started(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token
      )
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token,
        offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    it 'republishes the lane under the new tier 5-tuple, preserving model and instance identity' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :cloud)

      before_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first
      instance_id = ssot_harness.instance_id(instance_config: config)
      expected_before = Legion::Extensions::Llm::Inventory::Identity.compose_lane_id(
        tier: :cloud, provider_family: :bedrock, instance_id: instance_id,
        type: Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: before_lane.operation),
        model: before_lane.model
      )
      expect(before_lane.lane_id).to eq(expected_before)

      frontier_drafts = ssot_harness.build_offering_drafts(
        instance_config: config, callable: context[:callable], tier: :frontier
      )
      context[:publisher].replace_instance_snapshot(
        instance_id: ssot_harness.instance_id(instance_config: config),
        physical_id: ssot_harness.physical_id(instance_config: config),
        publisher_token: context[:token],
        offerings: frontier_drafts,
        sequence: 1
      )

      after_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first
      expected_after = Legion::Extensions::Llm::Inventory::Identity.compose_lane_id(
        tier: :frontier, provider_family: :bedrock, instance_id: instance_id,
        type: Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: after_lane.operation),
        model: after_lane.model
      )

      # The 5 tuple reproduces from the record's own fields, and the tier
      # change moved ONLY the tier member — model and instance are preserved.
      expect(after_lane.lane_id).to eq(expected_after)
      expect(after_lane.lane_id).not_to eq(before_lane.lane_id)
      expect(after_lane.model).to eq(before_lane.model)
      expect(after_lane.instance_id).to eq(before_lane.instance_id)
      expect(registry.snapshot.lanes_for(instance_key: context[:key])).to all(have_attributes(tier: :frontier))
    end
  end

  # ─── Startup gating + initializing on initial failure ──────────────────────

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock,
        instance_id: ssot_harness.instance_id(instance_config: config),
        physical_id: ssot_harness.physical_id(instance_config: config)
      )
    end

    before do
      @publisher   = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
      @callable    = ssot_harness.build_callable(instance_config: config)
      @coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    it 'remains initializing until readiness probe succeeds' do
      iid = ssot_harness.instance_id(instance_config: config)
      @publisher.claim_instance(instance_id: iid, callable: @callable, probe_request_handle: @coordinator)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      iid = ssot_harness.instance_id(instance_config: config)
      token = @publisher.claim_instance(instance_id: iid, callable: @callable, probe_request_handle: @coordinator)
      probe = @publisher.readiness_probe_started(instance_id: iid, publisher_token: token)
      @publisher.readiness_failed(instance_id: iid, probe_token: probe,
                                  reason: 'Bedrock ListFoundationModels failed: AccessDenied')

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      iid   = ssot_harness.instance_id(instance_config: config)
      token = @publisher.claim_instance(instance_id: iid, callable: @callable, probe_request_handle: @coordinator)
      probe = @publisher.readiness_probe_started(instance_id: iid, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: @callable, tier: :cloud)
      @publisher.activate_instance_snapshot(
        instance_id: iid, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  # ─── Normalized instance-unavailable isolation ─────────────────────────────

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
      instance_id = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: instance_id, physical_id: physical_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(
        instance_id: instance_id, physical_id: physical_id, callable: callable, probe_request_handle: coordinator
      )
      probe = publisher.readiness_probe_started(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token
      )
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token,
        offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

      registry.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'ServiceUnavailableException from us-east-1'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    it 'normalizes ServiceUnavailableException as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it 'normalizes generic 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'normalizes ModelNotReadyException as model_not_ready' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.model_not_ready_error)
      expect(outcome.kind).to eq(:model_not_ready)
    end
  end

  # ─── Error classification table ───────────────────────────────────────────

  describe 'error isolation (no global poisoning)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs.first) }

    it 'classifies ThrottlingException as rate_limited' do
      error = Aws::BedrockRuntime::Errors::ThrottlingException.new(
        Seahorse::Client::RequestContext.new, 'Rate exceeded'
      )
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies AccessDeniedException as authorization' do
      error = Aws::BedrockRuntime::Errors::AccessDeniedException.new(
        Seahorse::Client::RequestContext.new, 'Access denied'
      )
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authorization)
    end

    it 'classifies ValidationException as invalid_request' do
      error = Aws::BedrockRuntime::Errors::ValidationException.new(
        Seahorse::Client::RequestContext.new, 'Validation error'
      )
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:invalid_request)
    end

    it 'classifies ResourceNotFoundException as model_missing' do
      error = Aws::BedrockRuntime::Errors::ResourceNotFoundException.new(
        Seahorse::Client::RequestContext.new, 'Not found'
      )
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:model_missing)
    end

    it 'classifies timeout errors as timeout' do
      error = Timeout::Error.new('execution expired')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies connection refused as connection_failure' do
      error = Errno::ECONNREFUSED.new('Connection refused')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies generic errors as provider_error' do
      error = RuntimeError.new('unexpected failure')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:provider_error)
    end

    it 'never returns instance_unavailable from generic service errors regardless of status' do
      [500, 502, 503, 504, 529].each do |status|
        error = Aws::BedrockRuntime::Errors::ServiceError.new(
          Seahorse::Client::RequestContext.new, "HTTP #{status}"
        )
        error.define_singleton_method(:http_status_code) { status }
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end
  end

  # ─── No Legion::LLM reverse dependency ────────────────────────────────────

  describe 'dependency isolation' do
    it 'does not require Legion::LLM in the discovery actor or runner' do
      project_root = File.expand_path('../../../..', __dir__)
      %w[actors/discovery.rb runners/discovery.rb].each do |relative|
        source = File.read(File.join(project_root, 'lib/legion/extensions/llm/bedrock', relative))
        expect(source).not_to match(/\bLegion::LLM\b/), "lib/legion/extensions/llm/bedrock/#{relative} references Legion::LLM"
      end
    end

    it 'Helpers::Callable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # ─── No default model/provider ────────────────────────────────────────────

  describe 'no default model or provider' do
    it 'permits "default" as an explicit instance_id' do
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: 'default'
      )
      expect(key.instance_id).to eq('default')
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :bedrock, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'offering drafts require an explicit model string' do
      good = ssot_harness.build_offering_drafts(
        instance_config: ssot_harness.instance_configs.first
      ).first
      expect do
        Legion::Extensions::Llm::Inventory::OfferingDraft.new(
          provider_native_key: 'test',
          model: '',
          tier: :cloud,
          operation_evidence: good.operation_evidence,
          context_evidence: good.context_evidence,
          max_output_evidence: good.max_output_evidence,
          embedding_dimensions_evidence: good.embedding_dimensions_evidence,
          model_revision_evidence: good.model_revision_evidence,
          tokenizer_evidence: good.tokenizer_evidence,
          quota_domains: {},
          metadata: {},
          publication_source: :provider_catalog
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  # ─── Helpers::Callable direct contract ─────────────────────────────────────

  describe Legion::Extensions::Llm::Bedrock::Helpers::Callable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'implements the fleet dispatch operations' do
      expect(callable).to respond_to(:chat)
      expect(callable).to respond_to(:stream_chat)
      expect(callable).to respond_to(:embed)
      expect(callable).to respond_to(:count_tokens)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end

    it 'uses the bounded exception class name as reason, never the message body (B9)' do
      long_message = 'request context: https://bedrock-runtime.us-east-1.amazonaws.com/secret-creds'
      error = RuntimeError.new(long_message)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.reason).to eq('RuntimeError')
      expect(outcome.reason).not_to include(long_message)
    end
  end

  # ─── Raw-string model dispatch (D15) ──────────────────────────────────────
  # The fleet WorkerExecution and legion-llm SelectionDispatch both pass
  # model: as a RAW STRING (the offering's model id). Bedrock's render path
  # normalizes through Capabilities#model_id (string-safe), so no
  # Model::Info wrap is needed — pin that contract here so a future render
  # path that calls model.id on a raw string fails loudly in CI.

  describe 'raw-string model dispatch (D15)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs.first) }
    let(:raw_model) { 'us.anthropic.claude-sonnet-4-6' }

    it 'dispatches chat with a raw string model' do
      result = callable.chat([], model: raw_model)
      expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(callable.dispatch_count).to eq(1)
    end

    it 'dispatches count_tokens with a raw string model' do
      result = callable.count_tokens(messages: [], model: raw_model)
      expect(result).to be_a(Hash)
    end
  end

  # ─── Dispatch boundary regression guards (live repro) ──────────────────────
  # The 2026-08-19 defect class: SSOT v3 local dispatch passed executor Hash
  # messages straight to the provider callable, and the provider's lenient hash
  # re-canonicalization masked the bypass. The boundary now rejects plain Hash
  # messages LOUDLY at both the callable (strict Canonical-only) and the
  # provider dispatch seam (Canonical-only).
  describe 'dispatch boundary regression guards (live repro)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs.first) }
    let(:provider) { Legion::Extensions::Llm::Bedrock::Provider.new(ssot_harness.instance_configs.first) }
    let(:hash_request) { [{ role: 'user', content: 'What is the capital of France?' }] }

    it 'rejects plain Hash messages at the callable dispatch boundary' do
      expect { callable.chat(hash_request, model: 'us.anthropic.claude-sonnet-4-6') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'rejects plain Hash messages at the provider dispatch seam' do
      expect { provider.chat(messages: hash_request, model: 'us.anthropic.claude-sonnet-4-6') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end
  end

  # ─── 0.8.0 canonical boundary kit (B1/B2) ─────────────────────────────────
  # The shared kit (09) run against the REAL callable boundary: the production
  # Helpers::Callable -> Bedrock::Provider round-trip. The AWS SDK transport is
  # stubbed (the gem's standing pattern); the converse stream fake yields
  # realistic wire events so the provider's real stream parser runs. Only the
  # canonical boundary must be real — and it is (the provider classes, not a
  # fake that returns canonical objects directly).
  describe '0.8.0 canonical boundary (kit B1/B2)' do
    let(:config) { ssot_harness.instance_configs.first }

    let(:provider) do
      p = Legion::Extensions::Llm::Bedrock::Provider.new(config)
      p.instance_variable_set(:@runtime_client, stubbed_runtime_client)
      p
    end

    let(:callable) do
      c = ssot_harness.build_callable(instance_config: config)
      c.instance_variable_set(:@provider, provider)
      c
    end

    # A converse event stream that fires a text delta, usage metadata, and a
    # stop — the handler-registration-then-fire shape of the real AWS SDK.
    def converse_stream_fake
      handlers = {}
      stream = Object.new
      stream.define_singleton_method(:method_missing) do |name, *_args, &block|
        next super unless name.to_s.start_with?('on_')

        (handlers[name] ||= []) << block
        nil
      end
      stream.define_singleton_method(:respond_to_missing?) do |name, _include_private = false|
        name.to_s.start_with?('on_')
      end
      stream.define_singleton_method(:fire!) do
        (handlers[:on_content_block_delta_event] || []).each do |h|
          h.call(Struct.new(:delta).new(Struct.new(:text).new('ok')))
        end
        (handlers[:on_metadata_event] || []).each do |h|
          h.call(Struct.new(:usage).new({ input_tokens: 1, output_tokens: 2 }))
        end
        (handlers[:on_message_stop_event] || []).each do |h|
          h.call(Struct.new(:stop_reason).new('end_turn'))
        end
      end
      stream
    end

    # Real stubbed SDK client for the non-streaming operations; converse_stream
    # is faked because the AWS SDK ships no canned event-stream stub.
    def stubbed_runtime_client
      real = Aws::BedrockRuntime::Client.new(region: 'us-east-1', stub_responses: true)
      make_stream = method(:converse_stream_fake)
      client = Object.new
      client.define_singleton_method(:converse_stream) do |**_request, &block|
        stream = make_stream.call
        block&.call(stream)
        stream.fire!
        nil
      end
      client.define_singleton_method(:method_missing) do |name, *args, &block|
        real.public_send(name, *args, &block)
      end
      client.define_singleton_method(:respond_to_missing?) do |name, include_private = false|
        name == :converse_stream || real.respond_to?(name, include_private)
      end
      client
    end

    it_behaves_like 'B1 — central canonical enforcement (08 F2)'
    # B3: the tools half of the same boundary — the bedrock funnel now
    # enforces Hash<name, Canonical::ToolDefinition> once, before rendering
    # (the Hash-tolerant invoke renderer that carried poison to the wire is
    # deleted; fleet-side rehydration is the W4 boundary's job, core side).
    it_behaves_like 'B1b — central canonical tool enforcement (H3)'
    it_behaves_like 'B2 — canonical outputs (05 O5, 08 R2)'
  end

  # ─── OfferingDraft structure ──────────────────────────────────────────────

  describe 'OfferingDraft structure' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud) }

    it 'produces valid OfferingDraft instances' do
      expect(drafts).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingDraft))
    end

    it 'includes all required operation evidence keys' do
      expected_ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.sort
      drafts.each do |draft|
        actual_ops = draft.operation_evidence.keys.sort
        expect(actual_ops).to eq(expected_ops)
      end
    end

    it 'sets publication_source to :provider_catalog' do
      drafts.each do |draft|
        expect(draft.publication_source).to eq(:provider_catalog)
      end
    end

    it 'records the config name as instance_id and the derived id as physical_id in metadata' do
      draft = drafts.first
      expect(draft.metadata[:instance_id]).to eq('us_prod')
      physical = "us-east-1/ak:#{Digest::SHA256.hexdigest('AKIAIOSFODNN7EXAMPLE1')[0, 8]}"
      expect(draft.metadata[:physical_id]).to eq(physical)
    end

    it 'uses frozen metadata without secret keys' do
      drafts.each do |draft|
        expect(draft.metadata).to be_frozen
        draft.metadata.each_key do |key|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
          expect(normalized).not_to include('credential')
          expect(normalized).not_to include('secret')
          expect(normalized).not_to include('apikey')
        end
      end
    end
  end

  # ─── ReadinessResult contract ─────────────────────────────────────────────

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end

  # ─── Stale and superseded probe non-recovery ──────────────────────────────

  describe 'stale/superseded readiness probe non-recovery' do
    def bring_up(config)
      publisher   = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
      iid         = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key         = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: iid, physical_id: physical_id
      )
      callable    = ssot_harness.build_callable(instance_config: config)
      coord       = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(
        instance_id: iid, physical_id: physical_id, callable: callable, probe_request_handle: coord
      )
      probe = publisher.readiness_probe_started(
        instance_id: iid, physical_id: physical_id, publisher_token: token
      )
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: iid, physical_id: physical_id, publisher_token: token,
        offerings: drafts, sequence: 0, probe_token: probe
      )
      { publisher: publisher, key: key, iid: iid, physical_id: physical_id, token: token, callable: callable }
    end

    let(:config) { ssot_harness.instance_configs[0] }

    it 'a stale probe started before unavailable does not recover the instance' do
      ctx = bring_up(config)

      # Capture a probe token started while the instance is active (the "stale" probe).
      # Its started_availability_revision is set to the current revision at this point.
      stale_probe = ctx[:publisher].readiness_probe_started(
        instance_id: ctx[:iid], physical_id: ctx[:physical_id], publisher_token: ctx[:token]
      )

      # Mark instance unavailable (bumps unavailable_revision above the probe's started_revision)
      registry.dispatch_instance_unavailable(
        instance_key: ctx[:key],
        publisher_token_id: ctx[:token].publisher_token_id,
        reason: 'ServiceUnavailableException — instance went down'
      )
      expect(registry.snapshot.instance(instance_key: ctx[:key]).availability.state).to eq(:unavailable)

      # The stale probe completes — but since started_revision < unavailable_revision,
      # the registry rejects recovery (returns reason: :stale_probe, does not transition to :available)
      ctx[:publisher].readiness_succeeded(
        instance_id: ctx[:iid], physical_id: ctx[:physical_id], probe_token: stale_probe
      )

      failure_msg = 'stale probe must not recover an instance that became unavailable after the probe was issued'
      expect(registry.snapshot.instance(instance_key: ctx[:key]).availability.state).to eq(:unavailable), failure_msg
    end

    it 'a superseded probe does not corrupt an instance recovered by a newer probe' do
      ctx = bring_up(config)

      # Bring the instance down so we can run two recovery probes
      registry.dispatch_instance_unavailable(
        instance_key: ctx[:key],
        publisher_token_id: ctx[:token].publisher_token_id,
        reason: 'test forced unavailable'
      )

      # Both probe_a and probe_b are started after unavailable; either can recover the instance.
      # probe_b finishes first (it is "newer" in the recovery race).
      probe_a = ctx[:publisher].readiness_probe_started(
        instance_id: ctx[:iid], physical_id: ctx[:physical_id], publisher_token: ctx[:token]
      )
      probe_b = ctx[:publisher].readiness_probe_started(
        instance_id: ctx[:iid], physical_id: ctx[:physical_id], publisher_token: ctx[:token]
      )

      # probe_b recovers the instance
      ctx[:publisher].readiness_succeeded(instance_id: ctx[:iid], physical_id: ctx[:physical_id], probe_token: probe_b)
      expect(registry.snapshot.instance(instance_key: ctx[:key]).availability.state).to eq(:available)

      # probe_a then also reports success — the registry must not corrupt or remove the instance
      ctx[:publisher].readiness_succeeded(instance_id: ctx[:iid], physical_id: ctx[:physical_id], probe_token: probe_a)

      failure_msg2 = 'superseded probe should not corrupt or remove an already-available instance'
      expect(registry.snapshot.instance(instance_key: ctx[:key])).not_to be_nil, failure_msg2
      expect(registry.snapshot.instance(instance_key: ctx[:key]).availability.state).to eq(:available)
    end
  end

  # ─── Quota domain safety ──────────────────────────────────────────────────

  describe 'quota domain derivation' do
    it 'does not declare quota_domains on offerings without authoritative credential identity' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)

      # The harness builds drafts without quota domains by default
      drafts.each do |draft|
        expect(draft.quota_domains).to be_a(Hash)
      end
    end
  end
end
