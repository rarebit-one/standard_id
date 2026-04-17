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
