module StandardId
  module Oauth
    class AuthorizationCodeFlow < TokenGrantFlow
      expect_params :client_id, :client_secret, :code
      permit_params :redirect_uri, :code_verifier

      def authenticate!
        @credential = validate_client_secret!(params[:client_id], params[:client_secret])

        @authorization_code = find_authorization_code(params[:code])
        unless @authorization_code&.valid_for_client?(params[:client_id])
          raise StandardId::InvalidGrantError, "Invalid or expired authorization code"
        end

        if params[:redirect_uri].present? && @authorization_code.redirect_uri != params[:redirect_uri]
          raise StandardId::InvalidGrantError, "Redirect URI mismatch"
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
          client_id: @credential.client_id,
          account: @authorization_code.account
        )
      end

      def subject_id
        @authorization_code.account_id
      end

      def client_id
        @credential.client_id
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
        @credential&.client_application
      end

      def token_account
        @authorization_code&.account
      end
    end
  end
end
