# frozen_string_literal: true

require 'digest'
require_relative '../callable'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

module Legion
  module Extensions
    module Llm
      module Bedrock
        module Actor
          # Operation evidence builders for DiscoveryRefresh.
          module DiscoveryOperationEvidenceHelpers
            private

            def build_operation_evidence(is_embedding:, streaming_supported:)
              now = Time.now.freeze
              if is_embedding
                embed_operations(now: now)
              else
                chat_operations(streaming_supported: streaming_supported, now: now)
              end
            end

            def embed_operations(now:)
              ops = %i[chat stream_chat image transcribe translate speak moderate]
              result = ops.to_h do |op|
                [op, op_evidence(operation: op, status: :unsupported, now: now)]
              end
              result[:embed] = op_evidence(operation: :embed, status: :supported, now: now)
              result[:count_tokens] = op_evidence(operation: :count_tokens, status: :unsupported, now: now)
              result
            end

            def chat_operations(streaming_supported:, now:)
              stream_status = streaming_supported ? :supported : :unknown
              {
                chat: op_evidence(operation: :chat, status: :supported, now: now),
                stream_chat: op_evidence(operation: :stream_chat, status: stream_status, now: now),
                embed: op_evidence(operation: :embed, status: :unsupported, now: now),
                image: op_evidence(operation: :image, status: :unsupported, now: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, now: now),
                translate: op_evidence(operation: :translate, status: :unsupported, now: now),
                speak: op_evidence(operation: :speak, status: :unsupported, now: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, now: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, now: now)
              }
            end

            def op_evidence(operation:, status:, now:)
              source = case status
                       when :unknown    then :default_false
                       when :supported  then :provider_catalog
                       else :provider_implementation
                       end
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: now
              )
            end
          end

          # Capability evidence builders for DiscoveryRefresh.
          module DiscoveryCapabilityEvidenceHelpers
            CONTEXT_WINDOWS = {
              'anthropic.claude-sonnet-4' => 200_000,
              'anthropic.claude-haiku-4' => 200_000,
              'anthropic.claude-opus-4' => 200_000,
              'anthropic.claude-3-5-sonnet' => 200_000,
              'anthropic.claude-3-5-haiku' => 200_000,
              'anthropic.claude-3-haiku' => 200_000,
              'anthropic.claude-3-opus' => 200_000,
              'anthropic.claude-3-sonnet' => 200_000,
              'meta.llama3' => 128_000,
              'meta.llama3-1' => 128_000,
              'meta.llama3-2' => 128_000,
              'meta.llama3-3' => 128_000,
              'mistral.mistral-large' => 128_000,
              'mistral.mistral-small' => 128_000,
              'amazon.titan-text-express' => 8_192,
              'amazon.titan-text-premier' => 32_000,
              'amazon.nova-pro' => 300_000,
              'amazon.nova-lite' => 300_000,
              'amazon.nova-micro' => 128_000
            }.freeze

            private

            def build_capability_evidence(input_mods:, output_mods:, streaming_supported:, model_id:)
              if output_mods.include?('embedding')
                return { embedding: cap_evidence(capability: :embedding, status: :supported,
                                                 source: :provider_catalog) }
              end

              evidence = { completion: cap_evidence(capability: :completion, status: :supported,
                                                    source: :provider_catalog) }
              if streaming_supported
                evidence[:streaming] = cap_evidence(capability: :streaming, status: :supported,
                                                    source: :provider_catalog)
              end
              if input_mods.include?('image')
                evidence[:vision] = cap_evidence(capability: :vision, status: :supported,
                                                 source: :provider_catalog)
              end
              evidence[:tools] = cap_evidence(capability: :tools, status: :supported,
                                              source: :provider_implementation)
              evidence[:thinking] = cap_evidence(
                capability: :thinking,
                status: thinking_status_for(model_id: model_id),
                source: thinking_source_for(model_id: model_id)
              )
              evidence
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end

            def thinking_status_for(model_id:)
              thinking_model?(model_id: model_id) ? :supported : :unknown
            end

            def thinking_source_for(model_id:)
              thinking_model?(model_id: model_id) ? :provider_catalog : :default_false
            end

            def thinking_model?(model_id:)
              mid = model_id.to_s
              mid.match?(/anthropic\.claude-(sonnet-4|opus-4|haiku-4)/) ||
                mid.match?(/anthropic\.claude-3-[57]-sonnet/)
            end

            def build_context_evidence(model_id:)
              ctx = CONTEXT_WINDOWS.find { |prefix, _| model_id.start_with?(prefix) }&.last
              klass = Legion::Extensions::Llm::Inventory::ValueEvidence
              if ctx
                klass.new(status: :known, value: ctx, source: :provider_catalog)
              else
                klass.new(status: :unknown, source: :absent)
              end
            end

            def build_max_output_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_embedding_dimensions_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_model_revision_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_tokenizer_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end

          # Model-discovery and offering-draft helpers for DiscoveryRefresh.
          module DiscoveryModelHelpers
            private

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              client = build_bedrock_client(instance_cfg: instance_cfg)
              response = client.list_foundation_models
              summaries = response.respond_to?(:model_summaries) ? Array(response.model_summaries) : []

              summaries.filter_map do |summary|
                model_id = extract_model_id(summary: summary)
                next if model_id.nil? || model_id.empty?

                build_offering_draft(model_id: model_id, summary: summary,
                                     instance_cfg: instance_cfg, instance_key: instance_key)
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'bedrock.actor.discover_offerings')
              []
            end

            def extract_model_id(summary:)
              if summary.respond_to?(:model_id)
                summary.model_id.to_s
              elsif summary.is_a?(Hash)
                (summary[:model_id] || summary['model_id']).to_s
              else
                ''
              end
            end

            def build_offering_draft(model_id:, summary:, instance_cfg:, instance_key:)
              tier = instance_cfg[:tier] || :cloud
              input_mods = extract_modalities(summary: summary, field: :input_modalities)
              output_mods = extract_modalities(summary: summary, field: :output_modalities)
              streaming = streaming_supported?(summary: summary)

              op_ev = build_operation_evidence(
                is_embedding: output_mods.include?('embedding'), streaming_supported: streaming
              )
              cap_ev = build_capability_evidence(
                input_mods: input_mods, output_mods: output_mods,
                streaming_supported: streaming, model_id: model_id
              )
              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                operation_evidence: op_ev,
                capability_evidence: cap_ev,
                context_evidence: build_context_evidence(model_id: model_id),
                max_output_evidence: build_max_output_evidence,
                embedding_dimensions_evidence: build_embedding_dimensions_evidence,
                model_revision_evidence: build_model_revision_evidence,
                tokenizer_evidence: build_tokenizer_evidence,
                quota_domains: build_quota_domains(instance_cfg: instance_cfg, model_id: model_id),
                metadata: build_offering_metadata(model_id: model_id, instance_key: instance_key),
                publication_source: :provider_catalog
              )
            end

            def extract_modalities(summary:, field:)
              mods = if summary.respond_to?(field)
                       Array(summary.public_send(field))
                     elsif summary.is_a?(Hash)
                       Array(summary[field])
                     else
                       []
                     end
              mods.map { |m| m.to_s.downcase }
            end

            def streaming_supported?(summary:)
              if summary.respond_to?(:response_streaming_supported)
                summary.response_streaming_supported == true
              elsif summary.is_a?(Hash)
                summary[:response_streaming_supported] == true
              else
                false
              end
            end

            def build_quota_domains(instance_cfg:, model_id:)
              region = resolve_region(instance_cfg: instance_cfg)
              fingerprint = derive_account_fingerprint(instance_cfg: instance_cfg)
              return {} unless fingerprint

              domain_id = "aws:#{fingerprint}:#{region}:#{model_id}"
              { chat: domain_id, stream_chat: domain_id, embed: domain_id }
            end

            def derive_account_fingerprint(instance_cfg:)
              credential_input = instance_cfg[:bedrock_access_key_id] ||
                                 instance_cfg[:bearer_token] ||
                                 instance_cfg[:bedrock_profile]
              return nil unless credential_input

              ::Digest::SHA256.hexdigest(credential_input.to_s)[0, 8]
            end

            def build_offering_metadata(model_id:, instance_key:)
              { raw_model: model_id, instance_id: instance_key.instance_id }
            end
          end

          # Health check and AWS client helpers for DiscoveryRefresh.
          module DiscoveryHealthHelpers
            private

            def check_health(instance_cfg:)
              client = build_bedrock_client(instance_cfg: instance_cfg)
              client.list_foundation_models
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: true,
                reason: 'Bedrock ListFoundationModels succeeded',
                metadata: { region: resolve_region(instance_cfg: instance_cfg) }
              )
            rescue Aws::Bedrock::Errors::ServiceError => e
              readiness_failure(reason: "Bedrock ListFoundationModels failed: #{e.message}", error: e)
            rescue StandardError => e
              readiness_failure(reason: "Bedrock health check error: #{e.message}", error: e)
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: reason, metadata: { error_class: error.class.name }
              )
            end

            def build_bedrock_client(instance_cfg:)
              require 'aws-sdk-bedrock'
              Aws::Bedrock::Client.new(client_options_for(instance_cfg: instance_cfg))
            end

            def client_options_for(instance_cfg:)
              opts = { region: resolve_region(instance_cfg: instance_cfg) }
              endpoint = instance_cfg[:bedrock_endpoint]
              opts[:endpoint] = endpoint if endpoint
              bearer = instance_cfg[:bearer_token]
              if bearer.is_a?(String) && !bearer.strip.empty?
                opts[:token_provider] = Aws::StaticTokenProvider.new(bearer)
              else
                creds = resolve_credentials(instance_cfg: instance_cfg)
                opts[:credentials] = creds if creds
              end
              opts.compact
            end

            def resolve_credentials(instance_cfg:)
              profile = instance_cfg[:bedrock_profile]
              return Aws::SharedCredentials.new(profile_name: profile) if profile.is_a?(String) && !profile.strip.empty?

              akid = instance_cfg[:bedrock_access_key_id]
              return nil unless akid.is_a?(String) && !akid.strip.empty?

              Aws::Credentials.new(akid, instance_cfg[:bedrock_secret_access_key], instance_cfg[:bedrock_session_token])
            end
          end

          # Instance identity and configuration helpers for DiscoveryRefresh.
          module DiscoveryConfigHelpers
            private

            def derive_instance_id(instance_cfg:)
              region = resolve_region(instance_cfg: instance_cfg)
              cred = derive_credential_fingerprint(instance_cfg: instance_cfg)
              "#{region}/#{cred}"
            end

            def derive_credential_fingerprint(instance_cfg:)
              bearer  = instance_cfg[:bearer_token]
              akid    = instance_cfg[:bedrock_access_key_id]
              profile = instance_cfg[:bedrock_profile]

              if bearer.is_a?(String) && !bearer.strip.empty?
                "bearer:#{::Digest::SHA256.hexdigest(bearer)[0, 8]}"
              elsif akid.is_a?(String) && !akid.strip.empty?
                "ak:#{::Digest::SHA256.hexdigest(akid)[0, 8]}"
              elsif profile.is_a?(String) && !profile.strip.empty?
                "profile:#{profile}"
              else
                'default-chain'
              end
            end

            def resolve_region(instance_cfg:)
              instance_cfg[:bedrock_region] || instance_cfg[:region] || 'us-east-1'
            end

            def configured_instances
              instances = {}
              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  instances[name.to_sym] = normalize_instance_config(config: config)
                end
              end
              instances[:default_instance] = build_default_instance_config if instances.empty?
              instances
            end

            def build_default_instance_config
              inst  = settings[:instances][:default]
              creds = inst[:credentials]
              prov  = inst[:provider]
              {
                bedrock_region: inst[:region],
                bedrock_geo_prefix: inst[:geo_prefix],
                bearer_token: creds[:bearer_token],
                bedrock_access_key_id: creds[:access_key_id],
                bedrock_secret_access_key: creds[:secret_access_key],
                bedrock_session_token: creds[:session_token],
                bedrock_profile: creds[:profile],
                bedrock_endpoint: prov[:endpoint],
                tier: inst[:tier]
              }.compact
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              normalized[:bedrock_region]            ||= normalized.delete(:region)
              normalized[:bedrock_geo_prefix]        ||= normalized.delete(:geo_prefix)
              normalized[:bedrock_endpoint]          ||= normalized.delete(:endpoint)
              normalized[:bedrock_access_key_id]     ||= normalized.delete(:access_key_id)
              normalized[:bedrock_secret_access_key] ||= normalized.delete(:secret_access_key)
              normalized[:bedrock_session_token]     ||= normalized.delete(:session_token)
              normalized[:bedrock_profile]           ||= normalized.delete(:profile)
              normalized[:tier] ||= :cloud
              normalized
            end
          end

          # Probe lifecycle helpers for DiscoveryRefresh.
          module DiscoveryProbeHelpers
            private

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe
              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => cleanup_error
                handle_exception(cleanup_error, level: :warn, operation: 'bedrock.actor.cadence_probe.cleanup',
                                                instance_id: instance_id)
              end
              handle_exception(e, level: :warn, operation: 'bedrock.actor.cadence_probe', instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)
              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              begin
                coordinator&.finish_probe(request: request)
              rescue StandardError => cleanup_error
                handle_exception(cleanup_error, level: :warn, operation: 'bedrock.actor.reactive_probe.cleanup',
                                                instance_id: instance_id)
              end
              handle_exception(e, level: :warn, operation: 'bedrock.actor.reactive_probe', instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(instance_id: instance_id, probe_token: probe_token, reason: readiness.reason)
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'bedrock.actor.probe_enqueue', instance_id: instance_id)
                false
              end
            end
          end

          # Instance orchestration helpers: claim, refresh, shutdown.
          module DiscoveryOrchestrationHelpers
            private

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = derive_instance_id(instance_cfg: instance_cfg)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :bedrock, instance_id: instance_id
              )
              callable = BedrockCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: instance_id)
              )
              publisher_token = publisher.claim_instance(
                instance_id: instance_id, callable: callable, probe_request_handle: probe_coordinator
              )
              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              probe_token = publisher.readiness_probe_started(instance_id: instance_id,
                                                              publisher_token: publisher_token)
              readiness = check_health(instance_cfg: instance_cfg)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id, publisher_token: publisher_token,
                  offerings: offerings, sequence: 0, probe_token: probe_token
                )
              else
                publisher.readiness_failed(instance_id: instance_id, probe_token: probe_token, reason: readiness.reason)
              end

              @instance_states[instance_id] = {
                name: name, instance_key: instance_key, instance_cfg: instance_cfg,
                callable: callable, probe_coordinator: probe_coordinator,
                publisher_token: publisher_token, sequence: 0, offerings: offerings
              }
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id, publisher_token: state[:publisher_token],
                  offerings: new_offerings, sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end
              run_cadence_probe(instance_id: instance_id, state: state)
            end

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(instance_id: instance_id, publisher_token: state[:publisher_token])
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'bedrock.actor.remove_instance', instance_id: instance_id)
              end
              @instance_states.clear
            end
          end

          # SSOT v3 periodic discovery actor for Bedrock provider instances.
          # Claims instances per credential/region identity, discovers models
          # via ListFoundationModels, probes health via the same non-inference
          # control-plane call, and publishes complete OfferingDraft snapshots
          # through Inventory::Publisher. Supports coalesced reactive probes
          # after dispatch-triggered instance_unavailable transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper
            include DiscoveryOperationEvidenceHelpers
            include DiscoveryCapabilityEvidenceHelpers
            include DiscoveryModelHelpers
            include DiscoveryHealthHelpers
            include DiscoveryConfigHelpers
            include DiscoveryProbeHelpers
            include DiscoveryOrchestrationHelpers

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              settings[:discovery_interval]
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'bedrock.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'bedrock.actor.discovery_refresh.shutdown')
            end

            private

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :bedrock)
            end

            def initial_discovery
              @instance_states = {}
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'bedrock.actor.claim_instance', instance_name: name.to_s)
              end
            end

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'bedrock.actor.refresh_instance', instance_id: instance_id)
              end
            end
          end
        end
      end
    end
  end
end
