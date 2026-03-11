module StandardId
  module Testing
    # Integration test helpers for signing in accounts and making authenticated requests.
    #
    # Usage in rails_helper.rb:
    #
    #   require "standard_id/testing"
    #
    #   RSpec.configure do |config|
    #     config.include StandardId::Testing::RequestHelpers, type: :request
    #   end
    #
    module RequestHelpers
      # Create a browser session record for integration tests.
      #
      # For a simpler approach, use stub_web_authentication from AuthenticationHelpers instead.
      #
      # @param account [Object] the account to sign in
      # @param user_agent [String] the user agent string (default: "RSpec")
      # @return [StandardId::BrowserSession] the created session
      #
      def create_browser_session(account, user_agent: "RSpec")
        StandardId::BrowserSession.create!(
          account: account,
          ip_address: "127.0.0.1",
          user_agent: user_agent,
          expires_at: StandardId::BrowserSession.expiry
        )
      end

      # Build a JWT token for API/service authentication.
      #
      # @param account [Object, nil] account (uses account.id as sub claim)
      # @param sub [String, nil] explicit subject claim (overrides account.id)
      # @param client_id [String] OAuth client ID
      # @param scope [String] space-separated scopes
      # @param grant_type [String] OAuth grant type
      # @param extra [Hash] additional JWT claims
      # @return [String] encoded JWT token
      #
      def build_jwt(account: nil, sub: nil, client_id: "test-client",
                    scope: "openid", grant_type: "authorization_code", extra: {})
        sub ||= account&.id
        raise ArgumentError, "account or sub must be provided" if sub.nil?

        claims = { sub: sub, client_id: client_id, scope: scope, grant_type: grant_type }.merge(extra)
        StandardId::JwtService.encode(claims)
      end

      # Returns an Authorization header hash for Bearer token authentication.
      #
      # @param token [String] the JWT token
      # @return [Hash] header hash
      #
      def bearer_auth_header(token)
        { "Authorization" => "Bearer #{token}" }
      end
    end
  end
end
