module StandardId
  class ScopeConfig
    # @!attribute [r] allow_registration
    #   Reserved for future use — controls whether new accounts can register under this scope.
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

    # Shared deprecator instance. Creating a new ActiveSupport::Deprecation on
    # every extract_profile_types call bypasses the host app's configured
    # deprecation behaviour (Rails 7.1+ routes through deprecation registries)
    # and allocates for every scope init. One instance is enough.
    DEPRECATOR = ActiveSupport::Deprecation.new("2.0", "StandardId")

    # Normalize profile-type inputs from config.
    #
    # Accepts:
    #   - :profile_types (plural) — array of strings (preferred).
    #   - :profile_type  (singular) — single string, retained for back-compat. Emits a
    #     deprecation warning when present.
    #
    # Returns an Array<String> (possibly empty).
    def self.extract_profile_types(config)
      plural = config[:profile_types]
      singular = config[:profile_type]

      if singular && plural
        raise ArgumentError, "Scope config cannot set both :profile_type and :profile_types — use :profile_types"
      end

      if singular
        DEPRECATOR.warn(
          "StandardId scope config key :profile_type is deprecated and will be removed in v2.0. " \
            "Use :profile_types (an Array of profile-type strings) instead."
        )
        return Array(singular).map(&:to_s).reject(&:blank?)
      end

      Array(plural).map(&:to_s).reject(&:blank?)
    end

    def initialize(name, config = {})
      @name = name.to_sym
      @profile_types = self.class.extract_profile_types(config)
      @after_sign_in_path = config[:after_sign_in_path]
      @no_profile_message = config[:no_profile_message] || default_no_profile_message
      @label = config[:label] || name.to_s.humanize
      @allow_registration = config.fetch(:allow_registration, true)
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
