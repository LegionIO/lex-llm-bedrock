# frozen_string_literal: true

require 'digest'

module Legion
  module Extensions
    module Llm
      module Bedrock
        # Deterministic SSOT v3 physical-identity derivation for Bedrock
        # provider instances.
        #
        # Instance IDENTIFICATION is the operator's CONFIG NAME
        # (InstanceKey.instance_id). The value derived here is the SECONDARY
        # physical id (InstanceKey.physical_id) — region + credential
        # fingerprint — kept for dedup and diagnostics only. It never
        # participates in identity, tuning lookups, or routing.
        #
        # Single source of truth shared by the discovery actor and the
        # conformance harness. A config is only claimable when it carries a
        # resolvable credential; a credential-less config derives NO physical
        # id (nil) instead of a provider-family fallback.
        module InstanceIdentity
          module_function

          # Returns "region/<credential>" or nil when the config carries no
          # resolvable credential. The credential segment is never a
          # provider-family fallback identity.
          def derive_physical_id(instance_cfg:)
            credential = derive_credential_fingerprint(instance_cfg: instance_cfg)
            return nil unless credential

            "#{resolve_region(instance_cfg: instance_cfg)}/#{credential}"
          end

          # "bearer:<sha8>" | "ak:<sha8>" | "profile:<name>", or nil when the
          # config has no resolvable credential.
          def derive_credential_fingerprint(instance_cfg:)
            bearer  = instance_cfg[:bearer_token]
            akid    = instance_cfg[:bedrock_access_key_id]
            profile = instance_cfg[:bedrock_profile]

            if bearer.is_a?(::String) && !bearer.strip.empty?
              "bearer:#{::Digest::SHA256.hexdigest(bearer)[0, 8]}"
            elsif akid.is_a?(::String) && !akid.strip.empty?
              "ak:#{::Digest::SHA256.hexdigest(akid)[0, 8]}"
            elsif profile.is_a?(::String) && !profile.strip.empty?
              "profile:#{profile}"
            end
          end

          def resolve_region(instance_cfg:)
            instance_cfg[:bedrock_region] || instance_cfg[:region] || 'us-east-1'
          end
        end
      end
    end
  end
end
