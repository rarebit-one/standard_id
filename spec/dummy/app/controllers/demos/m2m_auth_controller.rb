module Demos
  class M2mAuthController < ApplicationController
    def index
      # Display how to request tokens and call protected APIs
      @example_token_request = {
        url: "/api/oauth/token",
        body: {
          grant_type: "client_credentials",
          client_id: "<client_id>",
          client_secret: "<client_secret>",
          audience: "https://dummy-api.example.com/",
          scope: "read:users write:orders"
        }
      }
    end
  end
end
