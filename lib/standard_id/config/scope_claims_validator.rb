module StandardId
  module Config
    # Validates that every claim referenced by `oauth.scope_claims` has a
    # matching entry in `oauth.claim_resolvers`. Without this check, a claim
    # listed against a scope but missing a resolver silently no-ops at token
    # issuance time — typos never surface.
    #
    # Missing resolvers raise ConfigurationError at boot. This is a
    # fail-loud-early check: the fix is trivial (add the resolver) and the
    # alternative (warn-only) encourages ignoring it.
    module ScopeClaimsValidator
      class << self
        def validate!(config = StandardId.config)
          scope_claims = config.oauth.scope_claims
          return if scope_claims.nil? || scope_claims.empty?

          resolvers = config.oauth.claim_resolvers || {}
          resolver_keys = normalize_keys(resolvers.keys)

          missing = {}
          scope_claims.each do |scope, claims|
            Array(claims).each do |claim|
              next if claim.nil?
              key = claim.to_s
              next if resolver_keys.include?(key)
              (missing[scope.to_s] ||= []) << claim
            end
          end

          return if missing.empty?

          details = missing.map { |scope, claims| "#{scope} -> #{claims.inspect}" }.join("; ")
          raise StandardId::ConfigurationError,
            "StandardId config: `oauth.scope_claims` references claim(s) with no resolver in " \
            "`oauth.claim_resolvers`: #{details}. Register a resolver for each claim or remove " \
            "it from scope_claims."
        end

        private

        def normalize_keys(keys)
          keys.map(&:to_s).to_set
        end
      end
    end
  end
end
