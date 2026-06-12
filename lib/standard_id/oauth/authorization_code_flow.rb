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

        if params[:redirect_uri].present? && @authorization_code.redirect_uri != params[:redirect_uri]
          raise StandardId::InvalidGrantError, "Redirect URI mismatch"
        end

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
