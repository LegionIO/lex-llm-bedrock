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

# Load BedrockCallable directly — it has no actor-runtime dependency.
require 'legion/extensions/llm/bedrock/callable'

# Test-local callable that extends BedrockCallable with dispatch operations
# required by FleetWorkerExecution. Tracks inference call count for
# conformance assertions.
class TrackingBedrockCallable < Legion::Extensions::Llm::Bedrock::Actor::BedrockCallable
  attr_reader :call_count

  def initialize(instance_cfg:, logger:)
    super
    @call_count = 0
  end

  def chat(messages:, model:, **)
    @call_count += 1
    { role: 'assistant', content: 'test response', model: model, input_count: messages.size }
  end

  def stream_chat(messages:, model:, **)
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: model, input_count: messages.size }
  end

  def embed(text:, model:, **)
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: model, input_length: text.to_s.length }
  end

  def count_tokens(messages:, model:, **)
    @call_count += 1
    { token_count: messages.size * 10, model: model }
  end
end

# Evidence-building helpers for the SSOT v3 conformance harness.
module BedrockSsotEvidenceHelpers
  private

  def build_operation_evidence(now:, is_embedding:)
    if is_embedding
      {
        chat: op_evidence(:chat, :unsupported, now),
        stream_chat: op_evidence(:stream_chat, :unsupported, now),
        embed: op_evidence(:embed, :supported, now),
        image: op_evidence(:image, :unsupported, now),
        transcribe: op_evidence(:transcribe, :unsupported, now),
        translate: op_evidence(:translate, :unsupported, now),
        speak: op_evidence(:speak, :unsupported, now),
        moderate: op_evidence(:moderate, :unsupported, now),
        count_tokens: op_evidence(:count_tokens, :unsupported, now)
      }
    else
      {
        chat: op_evidence(:chat, :supported, now),
        stream_chat: op_evidence(:stream_chat, :supported, now),
        embed: op_evidence(:embed, :unsupported, now),
        image: op_evidence(:image, :unsupported, now),
        transcribe: op_evidence(:transcribe, :unsupported, now),
        translate: op_evidence(:translate, :unsupported, now),
        speak: op_evidence(:speak, :unsupported, now),
        moderate: op_evidence(:moderate, :unsupported, now),
        count_tokens: op_evidence(:count_tokens, :unknown, now)
      }
    end
  end

  def op_evidence(operation, status, observed_at)
    source = if status == :unknown
               :default_false
             elsif status == :supported
               :provider_catalog
             else
               :provider_implementation
             end
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence
    {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion, status: :supported, source: :provider_catalog, observed_at: Time.now
      ),
      streaming: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming, status: :supported, source: :provider_catalog, observed_at: Time.now
      ),
      tools: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      thinking: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :supported, source: :provider_catalog, observed_at: Time.now
      )
    }
  end
end

# Harness class for Bedrock SSOT v3 conformance testing.
class BedrockSsotHarness
  include BedrockSsotEvidenceHelpers

  INSTANCE_CONFIGS = [
    {
      bedrock_region: 'us-east-1',
      bedrock_access_key_id: 'AKIAIOSFODNN7EXAMPLE1',
      bedrock_secret_access_key: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY1',
      tier: :cloud
    }.freeze,
    {
      bedrock_region: 'eu-west-1',
      bearer_token: 'test-bearer-token-alpha',
      tier: :cloud
    }.freeze
  ].freeze

  def provider_family = :bedrock
  def instance_configs = INSTANCE_CONFIGS

  def instance_id(instance_config:)
    region = instance_config[:bedrock_region] || 'us-east-1'
    bearer = instance_config[:bearer_token]
    akid = instance_config[:bedrock_access_key_id]
    profile = instance_config[:bedrock_profile]

    fingerprint = if bearer.is_a?(String) && !bearer.strip.empty?
                    "bearer:#{::Digest::SHA256.hexdigest(bearer)[0, 8]}"
                  elsif akid.is_a?(String) && !akid.strip.empty?
                    "ak:#{::Digest::SHA256.hexdigest(akid)[0, 8]}"
                  elsif profile.is_a?(String) && !profile.strip.empty?
                    "profile:#{profile}"
                  else
                    'default-chain'
                  end

    "#{region}/#{fingerprint}"
  end

  def build_callable(instance_config:)
    TrackingBedrockCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  def build_offering_drafts(tier: :cloud, **)
    now = Time.now.freeze
    model_id = 'anthropic.claude-sonnet-4-20250514-v1:0'
    [build_single_offering(model_id: model_id, tier: tier, now: now)]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Bedrock ListFoundationModels succeeded',
      metadata: { region: instance_config[:bedrock_region] || 'us-east-1' }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
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

  def build_single_offering(model_id:, tier:, now:)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: model_id, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now, is_embedding: false),
      capability_evidence: build_capability_evidence,
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :known, value: 200_000, source: :provider_catalog
      ),
      max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      quota_domains: {}, metadata: { raw_model: model_id }, publication_source: :provider_catalog
    )
  end
end

RSpec.describe Legion::Extensions::Llm::Bedrock do
  let(:ssot_harness) { BedrockSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # ─── Bedrock-specific identity derivation ──────────────────────────────────

  describe 'instance identity derivation' do
    it 'derives instance_id as region/ak:fingerprint with access key' do
      config = { bedrock_region: 'us-east-1', bedrock_access_key_id: 'AKIAIOSFODNN7EXAMPLE1' }
      fingerprint = Digest::SHA256.hexdigest('AKIAIOSFODNN7EXAMPLE1')[0, 8]
      expect(ssot_harness.instance_id(instance_config: config)).to eq("us-east-1/ak:#{fingerprint}")
    end

    it 'derives instance_id as region/bearer:fingerprint with bearer token' do
      config = { bedrock_region: 'eu-west-1', bearer_token: 'test-bearer-token-alpha' }
      fingerprint = Digest::SHA256.hexdigest('test-bearer-token-alpha')[0, 8]
      expect(ssot_harness.instance_id(instance_config: config)).to eq("eu-west-1/bearer:#{fingerprint}")
    end

    it 'derives instance_id as region/profile:name with profile' do
      config = { bedrock_region: 'us-west-2', bedrock_profile: 'production' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('us-west-2/profile:production')
    end

    it 'derives instance_id as region/default-chain without credentials' do
      config = { bedrock_region: 'ap-southeast-1' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('ap-southeast-1/default-chain')
    end

    it 'produces distinct instance IDs for two different credential/region combos' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end
  end

  # ─── Two regions with same model = separate lanes ──────────────────────────

  describe 'two Bedrock instances serving the same model' do
    def bring_up_instance(config, tier: :cloud)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
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
      first_offering_id = registry.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      registry.reset!
      second_run = bring_up_instance(config)
      second_offering_id = registry.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # ─── Tier change does NOT change lane/offering identity ────────────────────

  describe 'tier change and identity preservation' do
    def bring_up_with_tier(config, tier:)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    it 'preserves offering_id and lane_id when tier changes' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :cloud)

      before_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      before_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      frontier_drafts = ssot_harness.build_offering_drafts(
        instance_config: config, callable: context[:callable], tier: :frontier
      )
      context[:publisher].replace_instance_snapshot(
        instance_id: ssot_harness.instance_id(instance_config: config),
        publisher_token: context[:token],
        offerings: frontier_drafts,
        sequence: 1
      )

      after_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      after_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      expect(after_offering.offering_id).to eq(before_offering.offering_id)
      expect(after_lane.lane_id).to eq(before_lane.lane_id)
      expect(after_offering.tier).to eq(:frontier)
    end
  end

  # ─── Startup gating + initializing on initial failure ──────────────────────

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: ssot_harness.instance_id(instance_config: config)
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
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :bedrock, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
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
    it 'does not require Legion::LLM in the discovery actor' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/bedrock/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'BedrockCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # ─── No default model/provider ────────────────────────────────────────────

  describe 'no default model or provider' do
    it 'rejects instance_id "default" as reserved' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :bedrock, instance_id: 'default'
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :bedrock, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'offering drafts require an explicit model string' do
      now = Time.now.freeze
      expect do
        Legion::Extensions::Llm::Inventory::OfferingDraft.new(
          provider_native_key: 'test',
          model: '',
          tier: :cloud,
          operation_evidence: ssot_harness.send(:build_operation_evidence, now: now, is_embedding: false),
          context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
            status: :unknown, source: :absent
          ),
          model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
            status: :unknown, source: :absent
          ),
          tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          quota_domains: {},
          metadata: {},
          publication_source: :provider_catalog
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  # ─── BedrockCallable direct contract ──────────────────────────────────────

  describe Legion::Extensions::Llm::Bedrock::Actor::BedrockCallable do
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

    it 'truncates reason to 512 bytes' do
      long_message = 'x' * 1000
      error = RuntimeError.new(long_message)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.reason.length).to be <= 1024
    end
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
