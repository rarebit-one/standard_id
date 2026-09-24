module StandardId
  class ScopeConfig
    # @!attribute [r] allow_registration
    #   Whether passwordless sign-in under this scope may create a new account
    #   (default true). It can only RESTRICT: registration happens iff the
    #   global switch allows it (web.passwordless_registration for the
    #   WebEngine; the caller's `allow_registration:` for host controllers using
    #   StandardId::PasswordlessFlow) AND this is true. See #allow_registration?.
    # @!attribute [r] profile_types
    #   Array of profile-type class names accepted by this scope. Any profile matching any of
    #   these types satisfies the built-in profile check.
    # @!attribute [r] authorizer
    #   Optional per-scope callable invoked after the profile-type check. Signature:
    #     ->(account:, profile:, scope:) { ... }
    #   Receives the authenticated account, the matched profile (or nil when the scope has no
    #   profile_types), and the ScopeConfig itself. Return false (or nil) to deny sign-in; any
    #   truthy value permits it. Denial raises AuthenticationDenied using the scope's
    #   no_profile_message.
    attr_reader :name,
                :profile_types,
                :after_sign_in_path,
                :no_profile_message,
                :label,
                :allow_registration,
                :authorizer

    # Normalize profile-type inputs from config.
    #
    # Accepts :profile_types — an Array of profile-type class names (a single
    # String is wrapped). The singular :profile_type key was removed in 0.43
    # (deprecated in 0.42) and now raises: silently ignoring it would leave the
    # scope with NO profile requirement, admitting every account.
    #
    # @return [Array<String>] possibly empty
    # @raise [StandardId::ConfigurationError] when the removed :profile_type key is present
    def self.extract_profile_types(config)
      if config.key?(:profile_type) || config.key?("profile_type")
        raise StandardId::ConfigurationError,
          "StandardId scope config key :profile_type was removed in StandardId 0.43. " \
          "Use profile_types: [...] (an Array of profile-type class names) instead."
      end

      Array(config[:profile_types]).map(&:to_s).reject(&:blank?)
    end

    # Build every scope in StandardId.config.scopes once, so a scope config the
    # gem can no longer read (e.g. the removed :profile_type key) fails at boot
    # rather than on the first sign-in under that scope. Run by the engine.
    #
    # @return [void]
    # @raise [StandardId::ConfigurationError]
    def self.validate_all!(scopes = StandardId.config.scopes)
      return if scopes.blank?

      scopes.each { |name, scope_hash| new(name, scope_hash || {}) }
    end

    def initialize(name, config = {})
      @name = name.to_sym
      @profile_types = self.class.extract_profile_types(config)
      @after_sign_in_path = config[:after_sign_in_path]
      @no_profile_message = config[:no_profile_message] || default_no_profile_message
      @label = config[:label] || name.to_s.humanize
      # A present-but-nil key means "not configured", i.e. the default (true).
      @allow_registration = config[:allow_registration].nil? ? true : config[:allow_registration]
      @authorizer = config[:authorizer]
    end

    # Back-compat accessor. Returns the first configured profile type (or nil).
    # Prefer #profile_types for new code — a scope may accept more than one type.
    def profile_type
      @profile_types.first
    end

    def requires_profile?
      @profile_types.any?
    end

    def accepts_profile_type?(type)
      return false if type.blank?
      @profile_types.include?(type.to_s)
    end

    def authorizer?
      authorizer.respond_to?(:call)
    end

    def allow_registration?
      allow_registration != false
    end

    # Combine a global/caller registration switch with a (possibly nil) scope.
    # No scope → the global value unchanged; a scope can only turn it off.
    #
    # @param global [Boolean]
    # @param scope_config [StandardId::ScopeConfig, nil]
    def self.registration_allowed?(global, scope_config)
      return false unless global
      scope_config.nil? || scope_config.allow_registration?
    end

    private

    def default_no_profile_message
      if @profile_types.length > 1
        "Access denied. No matching profile found (expected one of: #{@profile_types.join(', ')})."
      else
        "Access denied. No matching profile found."
      end
    end
  end
end
