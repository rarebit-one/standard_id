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
      def initialize(account:, audience:, grant_type:, scopes: nil, client_id: nil, claims: {}, expires_in: nil,
        refresh_token: false, request: nil, auth_method: nil, auth_provider: nil)
        super({ audience: audience }, request || NullRequest.new)
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
