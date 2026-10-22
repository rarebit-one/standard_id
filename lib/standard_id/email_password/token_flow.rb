module StandardId
  module EmailPassword
    # Mints the token response for an account that Authentication or
    # Verification has just proven, through the same pipeline as every other
    # grant: login-method policy (flow :api_email_password), audience checks,
    # claims, OAUTH_TOKEN_ISSUING / OAUTH_TOKEN_ISSUED (so AccountStatus and
    # AccountLocking refuse), refresh token and session persistence.
    #
    # client_id, scope and audience come from `c.email_password.token_*`,
    # never from the request. Not reachable from /oauth/token.
    class TokenFlow < StandardId::Oauth::TokenGrantFlow
      def initialize(account:, request:)
        super({}, request)
        @account = account
      end

      def authenticate!
        raise StandardId::InvalidGrantError, "Account is required" if @account.blank?
      end

      private

      def login_method_policy_context
        { auth_method: :password, flow: :api_email_password }
      end

      def subject_id = @account.id
      def client_id = EmailPassword.config.token_client_id
      def token_scope = EmailPassword.config.token_scope
      def audience = EmailPassword.config.token_audience
      def grant_type = "password"
      def supports_refresh_token? = true
      def token_account = @account
    end
  end
end
