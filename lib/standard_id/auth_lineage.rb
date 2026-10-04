module StandardId
  # Carries the method an authentication was established with (password,
  # passwordless, social + provider, ...) along everything derived from it, so
  # `config.login_method_policy` can be consulted again on the `refresh_token`
  # grant with the ORIGINAL method:
  #
  #   web sign-in ──▶ BrowserSession#metadata ──▶ AuthorizationCode#metadata
  #   (/authorize, consent)                         │
  #   password / passwordless_otp / social grants ──┴─▶ RefreshToken#auth_method,
  #                                                     #auth_provider
  #   refresh_token grant: copied from the presented token to its successor.
  #
  # Sessions and authorization codes already have a JSON `metadata` column, so
  # the lineage lives there under "auth_method" / "auth_provider". Refresh tokens
  # get two columns (migration 20261004000000). Anything minted before 0.45, or
  # before that migration ran, has no recorded method and reaches the policy as
  # `:unspecified` — a restrictive policy refuses it (fails closed).
  module AuthLineage
    METHOD_KEY = "auth_method".freeze
    PROVIDER_KEY = "auth_provider".freeze

    module_function

    # @return [Hash] `{ auth_method: String|nil, auth_provider: String|nil }`
    def build(auth_method, provider = nil)
      { auth_method: auth_method&.to_s.presence, auth_provider: provider&.to_s.presence }
    end

    def empty
      build(nil, nil)
    end

    # Lineage stored on a session or authorization code `metadata` hash.
    def from_metadata(metadata)
      metadata = metadata.is_a?(Hash) ? metadata.stringify_keys : {}
      build(metadata[METHOD_KEY], metadata[PROVIDER_KEY])
    end

    def from_session(session)
      return empty unless session.respond_to?(:metadata)

      from_metadata(session.metadata)
    end

    def from_refresh_token(record)
      return empty unless record && refresh_token_columns?

      build(record.auth_method, record.auth_provider)
    end

    # Merge into a `metadata` hash. Nothing is added for an empty lineage.
    def to_metadata(lineage)
      { METHOD_KEY => lineage[:auth_method], PROVIDER_KEY => lineage[:auth_provider] }.compact
    end

    # Attributes for a new RefreshToken row; empty until the host has run the
    # migration, so a rolling deploy never writes to a column that is not there.
    def refresh_token_attributes(lineage)
      return {} unless refresh_token_columns?

      { auth_method: lineage[:auth_method], auth_provider: lineage[:auth_provider] }
    end

    # The policy's view: missing method → :unspecified.
    def policy_arguments(lineage)
      { auth_method: (lineage[:auth_method].presence || :unspecified).to_sym, provider: lineage[:auth_provider] }
    end

    def refresh_token_columns?
      StandardId::RefreshToken.column_names.include?("auth_method")
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end
end
