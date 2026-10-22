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

      # Bearer headers for an account, in one call: build_jwt + bearer_auth_header.
      #
      #   get "/api/orders", headers: bearer_headers_for(account, scope: "orders.read")
      #
      # @param account [Object] the account (its id becomes the sub claim)
      # @param jwt_options [Hash] any other build_jwt keyword (scope:, client_id:, extra:, ...)
      # @return [Hash] header hash
      #
      def bearer_headers_for(account, **jwt_options)
        bearer_auth_header(build_jwt(account: account, **jwt_options))
      end

      # Sign an account in for the following requests in a request spec,
      # without driving a login form or stubbing controllers.
      #
      # Creates a real BrowserSession and writes the same encrypted
      # `session_token` cookie that Web::SessionManager writes on a real
      # sign-in, so `current_account`, `require_browser_session!` and the
      # session's expiry and revocation all behave exactly as in production.
      # With `scope:`, it also writes the Rails session cookie carrying
      # `standard_id_scopes` (what `current_scope_names` reads), which needs
      # the cookie session store; any other store raises ArgumentError.
      #
      # Nothing is added to the app: the cookies are built with the app's own
      # encrypted cookie jar and secret_key_base, so there is no test-only route
      # to forget to remove. Like a real sign-in (which resets the session), it
      # always replaces the Rails session cookie: an earlier request's session
      # data, and an earlier sign_in_as's scopes, never carry over to this
      # account.
      #
      #   sign_in_as(account)
      #   sign_in_as(account, scope: :platform)
      #   get "/dashboard"
      #
      # @param account [Object] the account to sign in
      # @param scope [Symbol, String, Array, nil] scope name(s) to grant
      # @param user_agent [String] stored on the BrowserSession
      # @return [StandardId::BrowserSession] the session that was created
      #
      def sign_in_as(account, scope: nil, user_agent: "RSpec")
        ensure_cookie_session_store! if scope
        browser_session = create_browser_session(account, user_agent: user_agent)
        jar = standard_id_cookie_jar

        jar.encrypted[:session_token] = {
          value: browser_session.token,
          expires: browser_session.expires_at,
          httponly: true
        }
        cookies[:session_token] = jar[:session_token]

        if scope
          write_standard_id_scopes(jar, scope)
        elsif (key = rails_session_key)
          cookies.delete(key)
        end
        browser_session
      end

      private

      # The host app's cookie jar, outside any request: same secret_key_base,
      # salts, serializer and rotations as a real request, so the cookies it
      # writes read back exactly as Web::SessionManager's own.
      def standard_id_cookie_jar
        ActionDispatch::Request.new(Rails.application.env_config.deep_dup).cookie_jar
      end

      # Checked before anything is created, so a refused call leaves no session.
      def ensure_cookie_session_store!
        store = Rails.application.config.session_store
        unless store.is_a?(Class) && store <= ActionDispatch::Session::CookieStore
          raise ArgumentError,
            "sign_in_as(scope:) writes the Rails session cookie, so it needs the cookie " \
            "session store; this app uses #{store.inspect}. " \
            "Sign in through the app's own scoped login request instead."
        end
        return if rails_session_key

        raise ArgumentError,
          "sign_in_as(scope:) needs the session cookie name (config.session_options[:key]), and it is not set"
      end

      def rails_session_key
        Rails.application.config.session_options[:key]&.to_s
      end

      def write_standard_id_scopes(jar, scope)
        key = rails_session_key
        jar.encrypted[key] = {
          value: {
            "session_id" => SecureRandom.hex(16),
            "standard_id_scopes" => Array(scope).map(&:to_s)
          },
          httponly: true
        }
        cookies[key] = jar[key]
      end
    end
  end
end
