module StandardId
  module Oauth
    class AuthorizationCodeFlow < TokenGrantFlow
      expect_params :client_id, :code
      permit_params :client_secret, :redirect_uri, :code_verifier

      def authenticate!
        @client = StandardId::ClientApplication.find_by(client_id: params[:client_id])
        raise StandardId::InvalidClientError, "Client authentication failed" if @client.nil?

        # Confidential clients authenticate with a client secret. Public clients
        # (e.g. native/SPA/MCP clients per RFC 8252 / OAuth 2.1) cannot keep a
        # secret and authenticate via PKCE alone — they MUST NOT send one.
        if @client.confidential?
          @credential = validate_client_secret!(params[:client_id], params[:client_secret])
        elsif params[:client_secret].present?
          raise StandardId::InvalidClientError, "Public clients must not send a client_secret"
        end

        @authorization_code = find_authorization_code(params[:code])
        unless @authorization_code&.valid_for_client?(params[:client_id])
          raise StandardId::InvalidGrantError, "Invalid or expired authorization code"
        end

        validate_redirect_uri!

        # Fail closed: a public client's only authentication factor is PKCE, so a
        # code minted without a code_challenge offers no client authentication at
        # all. (pkce_valid? returns true when code_challenge is blank, which is
        # safe for confidential clients but would be a bypass for public ones.)
        if @client.public? && @authorization_code.code_challenge.blank?
          raise StandardId::InvalidGrantError, "PKCE is required for public clients"
        end

        unless @authorization_code.pkce_valid?(params[:code_verifier])
          raise StandardId::InvalidGrantError, "Invalid PKCE code_verifier"
        end

        @authorization_code.mark_as_used!
        emit_code_consumed
      end

      private

      # RFC 6749 §4.1.3: when the authorization request carried a redirect_uri,
      # the token request MUST repeat it and the values MUST be identical.
      #
      # A presented value is always compared (that has always been the case).
      # An OMITTED value is the interesting one: strictly it must be rejected,
      # but rejecting it unconditionally would break any live client that
      # relies on the historical leniency, so it is gated on
      # `config.oauth.strict_redirect_uri_matching` (default false) and logged
      # loudly in the meantime. See the schema comment for the migration path.
      def validate_redirect_uri!
        stored = @authorization_code.redirect_uri
        presented = params[:redirect_uri]

        if presented.present?
          raise StandardId::InvalidGrantError, "Redirect URI mismatch" if stored != presented
          return
        end

        return if stored.blank?

        unless StandardId.config.oauth.strict_redirect_uri_matching
          # Rails.logger, not StandardId.logger: the rest of lib/standard_id
          # logs through Rails directly, and config.logger is host-supplied
          # (it need not be a Logger at all).
          Rails.logger.warn(
            "[StandardId::AuthorizationCodeFlow] client #{params[:client_id]} redeemed an " \
            "authorization code minted with redirect_uri without sending one at the token " \
            "endpoint. RFC 6749 §4.1.3 requires it; this is accepted only because " \
            "config.oauth.strict_redirect_uri_matching is false."
          )
          return
        end

        raise StandardId::InvalidGrantError, "Redirect URI mismatch"
      end

      def emit_code_consumed
        StandardId::Events.publish(
          StandardId::Events::OAUTH_CODE_CONSUMED,
          authorization_code: @authorization_code,
          client_id: @client.client_id,
          account: @authorization_code.account
        )
      end

      def subject_id
        @authorization_code.account_id
      end

      def client_id
        @client.client_id
      end

      def token_scope
        @authorization_code.scope
      end

      def grant_type
        "authorization_code"
      end

      def supports_refresh_token?
        true
      end

      def find_authorization_code(code)
        StandardId::AuthorizationCode.lookup(code)
      end

      def token_client
        @client
      end

      def token_account
        @authorization_code&.account
      end

      def audience
        @authorization_code&.audience
      end

      def nonce
        @authorization_code&.nonce
      end
    end
  end
end
