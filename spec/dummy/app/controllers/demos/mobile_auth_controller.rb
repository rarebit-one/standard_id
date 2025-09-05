module Demos
  class MobileAuthController < ApplicationController
    def index
      # Display PKCE authorization code flow example
      @authorize_example = {
        url: "/api/authorize",
        params: {
          response_type: "code",
          client_id: "<mobile_client_id>",
          redirect_uri: "myapp://callback",
          code_challenge: "<code_challenge>",
          code_challenge_method: "S256",
          scope: "openid profile email",
          state: "<random_state>"
        }
      }

      @token_exchange_example = {
        url: "/api/oauth/token",
        body: {
          grant_type: "authorization_code",
          client_id: "<mobile_client_id>",
          code_verifier: "<code_verifier>",
          code: "<authorization_code>",
          redirect_uri: "myapp://callback"
        }
      }
    end
  end
end
