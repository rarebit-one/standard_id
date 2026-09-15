module StandardId
  module Oauth
    # Resolves the scope VOCABULARY a given audience is allowed to express —
    # the set of scope strings a client targeting that audience may request and
    # be granted. This is the hook an app uses to declare its per-audience MCP
    # scope vocabulary through the gem, rather than hard-coding a single flat
    # `scopes_supported` list that every audience shares.
    #
    # It is the scope-side counterpart to `AudienceProfileResolver`
    # (`c.oauth.audience_profile_types` + `c.oauth.audience_profile_resolver`):
    # that one binds an audience to the PROFILE an account must hold; this one
    # binds an audience to the SCOPES a client may carry. The two are read the
    # same way and configured the same way, on purpose.
    #
    # Configuration (both optional, both default to "unconfigured"):
    #
    #   # Static map: audience string => Array<String> of grantable scopes.
    #   c.oauth.audience_scopes = {
    #     "harness"       => %w[mcp mcp:read mcp:eval:run mcp:prompt:write],
    #     "companion_kit" => %w[mcp mcp:read],
    #     "admin_kit"     => %w[mcp mcp:read mcp:admin]
    #   }
    #
    #   # Optional callable, for apps that compute the vocabulary dynamically
    #   # (e.g. per-client entitlements). Receives keyword args
    #   # `(audience:, client:, configured_scopes:)` — any subset is accepted,
    #   # arguments are filtered by arity — and must return an Array<String>
    #   # (or nil to fall back to the static map for that audience).
    #   c.oauth.audience_scope_resolver = ->(audience:, client:, **) {
    #     Entitlements.mcp_scopes_for(client, audience)
    #   }
    #
    # When an audience is UNCONFIGURED (absent from the map and the resolver
    # returns nil / is unset), the vocabulary is empty and the enforcement
    # helpers below fail OPEN — they pass the requested scopes through
    # unchanged. This mirrors `audience_profile_types`: an app that does not
    # model per-audience scope vocabularies sees no behaviour change. Narrowing
    # only bites once an audience has an explicit vocabulary.
    #
    # @example
    #   StandardId::Oauth::AudienceScopeResolver.filter(
    #     requested: %w[mcp mcp:admin openid],
    #     audience: "companion_kit"
    #   ) # => ["mcp"]   (mcp:admin + openid are not in companion_kit's vocabulary)
    module AudienceScopeResolver
      class << self
        # The scope vocabulary for `audience` as an Array<String>.
        #
        # Resolution order:
        #   1. the configured callable `audience_scope_resolver`, when set and
        #      it returns a non-nil value — filtered by arity like every other
        #      gem callable, and handed the static-map value as
        #      `configured_scopes:` so it can extend rather than replace it;
        #   2. otherwise the static `audience_scopes` map entry;
        #   3. otherwise `[]` (unconfigured).
        #
        # Always returns a de-duplicated Array<String> with blanks removed.
        #
        # @param audience [String, Symbol, nil]
        # @param client [Object, nil] the ClientApplication in play, when known;
        #   passed through to the resolver callable for per-client vocabularies.
        # @return [Array<String>]
        def scopes_for(audience:, client: nil)
          return [] if audience.blank?

          configured = static_scopes_for(audience)

          resolver = StandardId.config.oauth.audience_scope_resolver
          if resolver.respond_to?(:call)
            filtered = StandardId::Utils::CallableParameterFilter.filter(
              resolver,
              { audience: audience.to_s, client: client, configured_scopes: configured }
            )
            resolved = resolver.call(**filtered)
            return normalize(resolved) unless resolved.nil?
          end

          configured
        end

        # True when `audience` has a non-empty scope vocabulary. Callers use
        # this to distinguish "audience is unconfigured, pass everything" from
        # "audience is configured with an empty vocabulary, allow nothing".
        def configured_for?(audience, client: nil)
          scopes_for(audience: audience, client: client).any?
        end

        # True when `scope` is within `audience`'s vocabulary. An unconfigured
        # audience permits every scope (fail-open) — see the module note.
        #
        # @param scope [String, Symbol]
        def permits?(scope:, audience:, client: nil)
          return false if scope.blank?

          vocabulary = scopes_for(audience: audience, client: client)
          return true if vocabulary.empty? # unconfigured -> fail open

          vocabulary.include?(scope.to_s)
        end

        # The subset of `requested` that `audience`'s vocabulary permits, in the
        # requested order, de-duplicated. An unconfigured audience returns the
        # requested scopes unchanged (fail-open). Use this to NARROW a grant
        # down to what the audience allows without raising.
        #
        # @param requested [Array<String>, String] space-delimited String or Array
        # @return [Array<String>]
        def filter(requested:, audience:, client: nil)
          req = normalize(requested)
          vocabulary = scopes_for(audience: audience, client: client)
          return req if vocabulary.empty? # unconfigured -> pass through

          allowed = vocabulary.to_set
          req.select { |s| allowed.include?(s) }
        end

        # The scopes in `requested` that `audience`'s vocabulary does NOT permit.
        # Empty for an unconfigured audience (nothing is out of vocabulary when
        # there is no vocabulary).
        #
        # @return [Array<String>]
        def disallowed(requested:, audience:, client: nil)
          req = normalize(requested)
          vocabulary = scopes_for(audience: audience, client: client)
          return [] if vocabulary.empty?

          allowed = vocabulary.to_set
          req.reject { |s| allowed.include?(s) }
        end

        # Strict, fail-closed variant for mint / registration enforcement.
        #
        # Returns the requested scopes (normalized) when every one is within the
        # audience's vocabulary, and raises `StandardId::InvalidScopeError` —
        # which renders as RFC 6749 `invalid_scope` — the moment one is not. An
        # unconfigured audience is a no-op pass-through (fail-open), so wiring
        # this into a mint path does not change behaviour for audiences that
        # have not opted in.
        #
        # The error message names the offending scopes (which are the CLIENT's
        # own request, not internal taxonomy) but never the full vocabulary, so
        # the endpoint does not become a scope-enumeration oracle.
        #
        # @raise [StandardId::InvalidScopeError]
        # @return [Array<String>]
        def assert!(requested:, audience:, client: nil)
          bad = disallowed(requested: requested, audience: audience, client: client)
          return normalize(requested) if bad.empty?

          raise StandardId::InvalidScopeError,
            "Scope(s) not permitted for audience '#{audience}': #{bad.join(', ')}"
        end

        private

        def static_scopes_for(audience)
          mapping = StandardId.config.oauth.audience_scopes || {}
          return [] if mapping.empty?

          normalize(mapping[audience.to_s] || mapping[audience.to_sym])
        end

        # Coerce a String (space-delimited) or Array into a clean, de-duplicated
        # Array<String>. Matches the space-delimited scope convention used by
        # ClientApplication#scopes_array and RFC 6749.
        def normalize(value)
          list =
            case value
            when nil then []
            when Array then value
            else value.to_s.split(/\s+/)
            end

          list.map { |s| s.to_s.strip }.reject(&:blank?).uniq
        end
      end
    end
  end
end
