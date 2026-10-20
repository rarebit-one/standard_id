module StandardId
  module Oauth
    # The grant behind StandardId::TokenMinter: a token for an account the host
    # has ALREADY authenticated by its own means (an operator console, a
    # service-to-service mint, a self-service "mint me a token" tool), minted
    # through the same pipeline as every other grant — audience validation,
    # audience → profile binding, scope_claims / claim_resolvers,
    # custom_claims, OAUTH_TOKEN_ISSUING / OAUTH_TOKEN_ISSUED (so AccountStatus
    # and AccountLocking refuse, and audit sees it), optional refresh token and
    # session persistence.
    #
    # Deliberately NOT reachable from /oauth/token: TokensController maps
    # grant_type strings to flows explicitly, and this one is never in that
    # map. The caller supplies the account; the flow authenticates nothing.
    class DirectMintFlow < TokenGrantFlow
      AUDIT_ERROR_MODES = %i[raise report].freeze

      def initialize(account:, audience:, grant_type:, scopes: nil, client_id: nil, claims: {}, expires_in: nil,
        refresh_token: false, request: nil, auth_method: nil, auth_provider: nil, profile: nil, audit_errors: :raise,
        requested_scopes: nil)
        super({ audience: audience }, request || NullRequest.new)
        @profile = profile
        @audit_requested_scopes = normalize_audit_scopes(requested_scopes)
        @audit_errors = audit_errors.to_s.to_sym
        unless AUDIT_ERROR_MODES.include?(@audit_errors)
          raise ArgumentError, "audit_errors must be one of #{AUDIT_ERROR_MODES.join(', ')} (got #{audit_errors.inspect})"
        end
        @account = account
        @audience = audience
        @grant_type = grant_type.to_s
        @scopes = normalize_scopes(scopes)
        @client_id = client_id.presence&.to_s
        @claims = claims.to_h.symbolize_keys
        @expires_in = expires_in
        @refresh_token = refresh_token
        @request_given = !request.nil?
        @auth_method = auth_method
        @auth_provider = auth_provider
      end

      # Public so TokenMinter can report the jti the audit event carried.
      def issued_jti
        @issued_jti
      end

      # The error an OAUTH_TOKEN_ISSUED subscriber raised under
      # `audit_errors: :report`, else nil.
      attr_reader :audit_error

      def authenticate!
        raise StandardId::InvalidGrantError, "Account is required" if @account.nil?
        raise StandardId::InvalidGrantError, "Account must be persisted" unless @account.respond_to?(:persisted?) && @account.persisted?
        raise StandardId::InvalidRequestError, "grant_type is required" if @grant_type.blank?
        # The refresh grant matches the token's client_id against the one the
        # caller presents, so a refreshable token with none could never be
        # redeemed.
        if @refresh_token && @client_id.nil?
          raise StandardId::InvalidRequestError, "client_id is required for a refreshable token"
        end
        if !@expires_in.nil? && @expires_in.to_i <= 0
          raise StandardId::InvalidRequestError, "expires_in must be a positive number of seconds"
        end
      end

      private

      # An explicit profile replaces the strict lookup: the host already knows
      # which of the account's profiles the token is for (several of one type
      # is legitimate there, and AmbiguousProfileError would refuse it). It
      # must still be the account's, active, and of the bound type when the
      # audience has a binding — the guarantees the lookup gives. Resolvers
      # receive it as `profile:` either way. config.oauth.audience_profile_resolver
      # is NOT consulted: the host chose the profile, so any extra gate that
      # resolver applies is the caller's to apply before minting.
      def enforce_audience_profile_binding!
        return super if @profile.nil?

        validate_explicit_profile!
        @resolved_profile = @profile
      end

      def validate_explicit_profile!
        unless profile_belongs_to_account?(@profile)
          raise StandardId::InvalidGrantError, "profile does not belong to the account"
        end
        if @profile.respond_to?(:active?) && !@profile.active?
          raise StandardId::InvalidGrantError, "profile is not active"
        end

        bound = profile_bound_audience
        return if bound.nil?

        types = StandardId::Oauth::AudienceProfileResolver.profile_types_for(bound)
        return if types.include?(StandardId::Oauth::AudienceProfileResolver.profile_type_for(@profile))

        raise StandardId::InvalidGrantError,
          "profile is not of a type bound to audience #{bound.inspect} (expected #{types.join(', ')})"
      end

      def profile_belongs_to_account?(profile)
        return profile.account_id.to_s == @account.id.to_s if profile.respond_to?(:account_id)
        return @account.profiles.include?(profile) if @account.respond_to?(:profiles)

        false
      end

      # Under `audit_errors: :report` a raising OAUTH_TOKEN_ISSUED subscriber
      # no longer costs the caller a token that is already signed (and, with a
      # refresh token, committed): the error is logged and handed back on the
      # result. OAUTH_TOKEN_ISSUING is never softened — its subscribers are the
      # account-status and locking guards.
      def emit_token_issued(expires_in)
        return super if @audit_errors == :raise

        begin
          super
        rescue StandardError => e
          @audit_error = e
          StandardId.config.logger&.error(
            "[StandardId] OAUTH_TOKEN_ISSUED subscriber raised for #{grant_type} (token still issued): " \
            "#{e.class}: #{e.message} at #{e.backtrace&.first}"
          )
        end
      end

      # A direct mint's caller may record what it actually granted (a
      # permission set carried in a host claim) rather than the scope words.
      def issued_event_requested_scopes
        @audit_requested_scopes.nil? ? super : @audit_requested_scopes
      end

      # No new authentication happened here: the host vouches for the account.
      def login_method_policy_context
        nil
      end

      def subject_id = @account.id
      def client_id = @client_id
      def token_scope = @scopes
      def grant_type = @grant_type
      def audience = @audience
      def token_account = @account
      def supports_refresh_token? = @refresh_token

      def token_client
        return nil if @client_id.nil?

        super
      end

      # An explicit lifetime wins (validated positive in authenticate!);
      # otherwise the configured lifetime for this grant_type key, falling
      # back to default_token_lifetime.
      def token_expiry
        return @expires_in.to_i.seconds unless @expires_in.nil?

        super
      end

      # What the host says about how it authenticated the account, recorded on
      # the refresh token so a restrictive login_method_policy can judge a
      # later refresh; nil is recorded as :unspecified, which such a policy
      # refuses — so pass it when a policy is configured.
      def refresh_token_auth_lineage
        StandardId::AuthLineage.build(@auth_method, @auth_provider)
      end

      # Resolvers and custom_claims see `request: nil` for a sessionless mint,
      # not the internal stand-in, so a `request&.…` guard takes the nil path.
      def claim_resolvers_context
        @claim_resolvers_context ||= super.merge(request: @request_given ? request : nil)
      end

      # Host-supplied claims ride on top of the standard payload and the
      # resolver-derived claims, but can never override a reserved JWT key or a
      # base session field (same rule as config.oauth.custom_claims).
      def build_jwt_payload(expires_in)
        extra = @claims.except(*StandardId::JwtService::RESERVED_JWT_KEYS, *StandardId::JwtService::BASE_SESSION_FIELDS)
        super(expires_in).merge(extra).compact
      end

      # A session is only materialised when the caller passed a real request:
      # the resolver and OauthSessionPersistence read remote_ip / user_agent
      # from it, and a programmatic mint with no request has no client to
      # describe. Machine-to-machine stays sessionless, as client_credentials is.
      def maybe_persist_session_for_token!
        return nil unless @request_given

        super
      end

      # nil keeps the scope words; otherwise an Array or a space-delimited
      # String, split like `scopes`.
      def normalize_audit_scopes(scopes)
        return nil if scopes.nil?

        Array(scopes).flat_map { |s| s.to_s.split(/\s+/) }.reject(&:blank?).uniq
      end

      def normalize_scopes(scopes)
        list = Array(scopes).flat_map { |s| s.to_s.split(/\s+/) }.reject(&:blank?).uniq
        list.empty? ? nil : list.join(" ")
      end

      # What the flow reads from a request when the caller gave none.
      class NullRequest
        def remote_ip = nil
        def user_agent = nil
        def params = {}
        def headers = {}
      end
    end
  end
end
