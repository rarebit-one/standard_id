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
  # It also carries WHEN that authentication happened (`authenticated_at`), so
  # step-up authentication (StandardId::StepUp) can tell how recently the
  # account proved its identity: Session#authenticated_at, "authenticated_at"
  # in an authorization code's metadata, RefreshToken#authenticated_at
  # (migration 20261123000000). A lineage with no time has no
  # `:authenticated_at` key at all.
  #
  # Sessions and authorization codes already have a JSON `metadata` column, so
  # the lineage lives there under "auth_method" / "auth_provider". Refresh tokens
  # get two columns (migration 20261004000000). Anything minted before 0.45, or
  # before that migration ran, has no recorded method and reaches the policy as
  # `:unspecified` — a restrictive policy refuses it (fails closed).
  module AuthLineage
    METHOD_KEY = "auth_method".freeze
    PROVIDER_KEY = "auth_provider".freeze
    AUTHENTICATED_AT_KEY = "authenticated_at".freeze

    module_function

    # @return [Hash] `{ auth_method: String|nil, auth_provider: String|nil }`,
    #   plus `authenticated_at: Time` when one is given
    def build(auth_method, provider = nil, authenticated_at: nil)
      lineage = { auth_method: auth_method&.to_s.presence, auth_provider: provider&.to_s.presence }
      lineage[:authenticated_at] = authenticated_at if authenticated_at
      lineage
    end

    def empty
      build(nil, nil)
    end

    # Lineage stored on a session or authorization code `metadata` hash.
    def from_metadata(metadata)
      metadata = metadata.is_a?(Hash) ? metadata.stringify_keys : {}
      build(metadata[METHOD_KEY], metadata[PROVIDER_KEY], authenticated_at: parse_time(metadata[AUTHENTICATED_AT_KEY]))
    end

    # A session's time is its own `authenticated_at` column, not its metadata.
    def from_session(session)
      return empty unless session.respond_to?(:metadata)

      lineage = from_metadata(session.metadata).except(:authenticated_at)
      authenticated_at = session.authenticated_at if session.respond_to?(:authenticated_at)
      lineage[:authenticated_at] = authenticated_at if authenticated_at
      lineage
    end

    def from_refresh_token(record)
      return empty unless record && refresh_token_columns?

      authenticated_at = record.authenticated_at if record.respond_to?(:authenticated_at)
      build(record.auth_method, record.auth_provider, authenticated_at: authenticated_at)
    end

    # Merge into a `metadata` hash. Nothing is added for an empty lineage.
    def to_metadata(lineage)
      {
        METHOD_KEY => lineage[:auth_method],
        PROVIDER_KEY => lineage[:auth_provider],
        AUTHENTICATED_AT_KEY => lineage[:authenticated_at]&.utc&.iso8601(6)
      }.compact
    end

    # Attributes for a new RefreshToken row; empty until the host has run the
    # migration, so a rolling deploy never writes to a column that is not there.
    def refresh_token_attributes(lineage)
      return {} unless refresh_token_columns?

      attributes = { auth_method: lineage[:auth_method], auth_provider: lineage[:auth_provider] }
      attributes[:authenticated_at] = lineage[:authenticated_at] if StandardId::StepUp.refresh_token_column?
      attributes
    end

    # The policy's view: missing method → :unspecified.
    def policy_arguments(lineage)
      { auth_method: (lineage[:auth_method].presence || :unspecified).to_sym, provider: lineage[:auth_provider] }
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def refresh_token_columns?
      StandardId::RefreshToken.column_names.include?("auth_method")
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end
end
