module StandardId
  # Resolves the `strict_loading:` option the gem's own associations declare,
  # from `StandardId.config.association_strict_loading`.
  #
  # WHY THIS EXISTS
  #
  # Apps that set `strict_loading_by_default = true` globally cannot fix the
  # gem's associations by re-declaring them: they are declared inside
  # `StandardId::AccountAssociations`, and `credentials` is a `has_many
  # :through`, where re-declaration risks ordering breakage. So two consuming
  # apps reached into Rails internals instead —
  #
  #     Account.reflect_on_association(assoc)&.options&.[]=(:strict_loading, false)
  #
  # — both with a comment asking for exactly this hook. Passing
  # `strict_loading:` at declaration time is the supported Rails API, and unlike
  # re-declaration it works for the `:through` association.
  #
  # WHY A HELPER RATHER THAN `strict_loading: config.association_strict_loading`
  #
  # Because `nil` must mean OMITTED, not `false`. Rails checks
  # `reflection.options.key?(:strict_loading)` *before* consulting the owner:
  #
  #     # ActiveRecord::Associations::Association#violates_strict_loading?
  #     return reflection.strict_loading? if reflection.options.key?(:strict_loading)
  #     owner.strict_loading? && !owner.strict_loading_n_plus_one_only?
  #
  # so declaring `strict_loading: nil` would put the key in the options hash and
  # make `reflection.strict_loading?` return `!!nil` == false — silently
  # disabling strict loading on every gem association in every app that never
  # asked for it. This returns an empty hash in that case instead, so the option
  # is genuinely absent and the owner's setting still governs.
  module AssociationStrictLoading
    module_function

    # Splat into a `has_many` / `has_one` / `belongs_to` declaration:
    #
    #   has_many :sessions, class_name: "StandardId::Session",
    #            **StandardId::AssociationStrictLoading.option
    #
    # @return [Hash] `{}` when unconfigured, else `{ strict_loading: <value> }`
    def option
      value = StandardId.config.association_strict_loading
      return {} if value.nil?

      { strict_loading: value }
    end

    # Associations declared with `**option`, as `owner_class_name => [names]`.
    # Used by the boot-time consistency check.
    #
    # Account's are keyed by the configured account class rather than listed
    # here, since the host owns that constant.
    GEM_OWNED = {
      "StandardId::Session" => %i[refresh_tokens],
      "StandardId::Identifier" => %i[credentials]
    }.freeze

    ACCOUNT_ASSOCIATIONS = %i[
      identifiers credentials sessions refresh_tokens client_applications
    ].freeze

    # Raise if a declared association disagrees with the configured value.
    #
    # The `included do` block in AccountAssociations reads the config when the
    # host's `Account` class body runs — during autoload, which can happen
    # *before* an initializer that sets `association_strict_loading`. The result
    # is silent: strict loading behaves as though the setting were never made,
    # and the app either raises StrictLoadingViolationError deep in a request or
    # quietly N+1s in production. This converts that into a boot failure that
    # names the ordering problem.
    #
    # Called from the Engine's `after_initialize`, when both the config and the
    # host's model are settled.
    #
    # @raise [StandardId::ConfigurationError]
    def verify_consistency!
      configured = StandardId.config.association_strict_loading
      return if configured.nil?

      mismatched = mismatched_associations(configured)
      return if mismatched.empty?

      raise StandardId::ConfigurationError, <<~MESSAGE.strip
        StandardId.config.association_strict_loading is #{configured.inspect}, but these
        associations were declared without it: #{mismatched.join(', ')}.

        This means the model class body ran BEFORE the config was set. StandardId's
        associations read the setting at declaration time, so it must be assigned in
        `config/initializers/standard_id.rb` — not in an `after_initialize` block, and
        not anywhere else that can run after your Account class is autoloaded.

        Left unchecked this fails silently: strict loading behaves as though you never
        made the setting, and the app either raises
        ActiveRecord::StrictLoadingViolationError inside a request or quietly N+1s in
        production.
      MESSAGE
    end

    def mismatched_associations(configured)
      pairs = GEM_OWNED.flat_map do |class_name, names|
        names.map { |name| [class_name.constantize, name] }
      end

      account_class = begin
        StandardId.account_class
      rescue StandardError
        nil
      end
      pairs += ACCOUNT_ASSOCIATIONS.map { |name| [account_class, name] } if account_class

      pairs.filter_map do |klass, name|
        reflection = klass.reflect_on_association(name)
        next if reflection.nil?
        next if reflection.options[:strict_loading] == configured

        "#{klass.name}##{name}"
      end
    end
  end
end
