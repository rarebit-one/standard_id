module StandardId
  module Oauth
    # Resolves the profile an account should be bound to for a given audience,
    # based on `StandardId.config.oauth.audience_profile_types`.
    #
    # The gem assumes the host app models profiles via `account.profiles`
    # (the same shape assumed by `LifecycleHooks::DEFAULT_PROFILE_RESOLVER`).
    # If the host app defines `StandardId.config.oauth.audience_profile_resolver`,
    # that callable is used instead of the built-in lookup.
    #
    # @example
    #   StandardId::Oauth::AudienceProfileResolver.call(
    #     account: current_account,
    #     audience: "admin_kit"
    #   )
    module AudienceProfileResolver
      class << self
        # Returns the profile record for `audience`, or nil when no matching
        # profile exists.
        #
        # Callers should check `profile_types_for(audience).blank?` first when
        # they need to distinguish "audience is unconfigured" from "account
        # lacks a profile for a configured audience".
        #
        # @param account [Object] the authenticated account (must respond to #profiles)
        # @param audience [String, nil] the matched audience string
        # @return [Object, nil]
        def call(account:, audience:)
          return nil if account.nil? || audience.blank?

          types = profile_types_for(audience)
          return nil if types.empty?

          resolver = StandardId.config.oauth.audience_profile_resolver
          if resolver.respond_to?(:call)
            filtered = StandardId::Utils::CallableParameterFilter.filter(
              resolver,
              { account: account, audience: audience, profile_types: types }
            )
            return resolver.call(**filtered)
          end

          default_lookup(account, types)
        end

        # Returns the configured profile types (always as an Array<String>) for
        # the given audience. Returns `[]` when no mapping is configured.
        def profile_types_for(audience)
          return [] if audience.blank?

          mapping = StandardId.config.oauth.audience_profile_types || {}
          return [] if mapping.empty?

          Array(mapping[audience.to_s] || mapping[audience.to_sym]).map(&:to_s).reject(&:blank?)
        end

        # True when audience_profile_types has a binding for `audience`.
        def configured_for?(audience)
          profile_types_for(audience).any?
        end

        # Strict variant of `.call` for mint-time enforcement: returns the
        # uniquely matching active profile, or raises a typed error so the
        # token grant flow can fail closed.
        #
        # Resolution rules (deterministic, no silent fallbacks):
        #   - 0 matching active profiles → raises `NoBoundProfileError`
        #     (NB: an inactive-only match is still 0 active matches and
        #     fails closed — inactive profiles cannot mint tokens)
        #   - exactly 1 matching active profile → returns it
        #   - >1 matching active profile → raises `AmbiguousProfileError`
        #
        # The legacy `.call` API preserves its "first active else first match"
        # behavior, since it is wired into the decode-time concern and host
        # apps may have grown to depend on its tolerance. Migrating that path
        # to strict mode is a separate change.
        #
        # @raise [StandardId::NoBoundProfileError]
        # @raise [StandardId::AmbiguousProfileError]
        def resolve!(account:, audience:)
          types = profile_types_for(audience)
          raise ArgumentError, "audience #{audience.inspect} has no profile binding" if types.empty?

          # Custom resolver path: trust the host app's result. It's expected
          # to enforce its own determinism — if it returns nil we still fail
          # closed; if it returns a profile we use it as-is.
          resolver = StandardId.config.oauth.audience_profile_resolver
          if resolver.respond_to?(:call)
            filtered = StandardId::Utils::CallableParameterFilter.filter(
              resolver,
              { account: account, audience: audience, profile_types: types }
            )
            resolved = resolver.call(**filtered)
            return resolved if resolved
            raise StandardId::NoBoundProfileError.new(
              audience: audience,
              expected_profile_types: types
            )
          end

          strict_default_lookup(account, audience, types)
        end

        private

        def default_lookup(account, types)
          return nil unless account.respond_to?(:profiles)

          candidates = account.profiles
          candidates = candidates.to_a unless candidates.is_a?(Array)

          matches = candidates.select do |profile|
            types.include?(profile_type_for(profile))
          end
          return nil if matches.empty?

          # Prefer a profile that reports itself as active? when that predicate
          # is available; otherwise fall back to the first match.
          active = matches.find { |p| p.respond_to?(:active?) && p.active? }
          active || matches.first
        end

        # Strict default lookup — counterpart to `default_lookup` for mint.
        #
        # "Active" semantics:
        #   - if a profile responds to `active?`, only `active? == true`
        #     counts toward the match set
        #   - if it does not, treat it as active (back-compat: not all host
        #     apps have an activity predicate)
        def strict_default_lookup(account, audience, types)
          unless account.respond_to?(:profiles)
            raise StandardId::NoBoundProfileError.new(
              audience: audience,
              expected_profile_types: types
            )
          end

          candidates = account.profiles
          candidates = candidates.to_a unless candidates.is_a?(Array)

          matches = candidates.select { |p| types.include?(profile_type_for(p)) }
          active_matches = matches.select { |p| !p.respond_to?(:active?) || p.active? }

          case active_matches.length
          when 0
            raise StandardId::NoBoundProfileError.new(
              audience: audience,
              expected_profile_types: types
            )
          when 1
            active_matches.first
          else
            raise StandardId::AmbiguousProfileError.new(
              audience: audience,
              expected_profile_types: types,
              profile_ids: active_matches.map { |p| p.respond_to?(:id) ? p.id : nil }.compact
            )
          end
        end

        def profile_type_for(profile)
          if profile.respond_to?(:profileable_type)
            profile.profileable_type.to_s
          elsif profile.respond_to?(:type)
            profile.type.to_s
          else
            profile.class.name.to_s
          end
        end
      end
    end
  end
end
