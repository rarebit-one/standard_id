require "rails_helper"

RSpec.describe "StandardId::Api::Oauth::TokensController", type: :request do
  # routes { StandardId::ApiEngine.routes }

  # let(:path) { "/api/oauth/token" }
  let(:path) { api_standard_id_api.oauth_token_path }

  describe "POST /api/oauth/token" do
    describe "error handling" do
      it "returns error when grant_type is missing" do
        post path, params: {}, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to eq("The grant_type parameter is required")
      end

      it "returns error for unsupported grant_type" do
        post path, params: { grant_type: "unsupported_grant" }, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("unsupported_grant_type")
        expect(body["error_description"]).to eq("Unsupported grant_type: unsupported_grant")
      end

      it "accepts application/x-www-form-urlencoded per RFC 6749" do
        post path, params: { grant_type: "client_credentials", client_id: "test", client_secret: "test", audience: "test" },
          headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

        # Should fail on invalid client, not content type
        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "accepts vendor-specific JSON content types" do
        post path, params: {}, headers: { "CONTENT_TYPE" => "application/vnd.api+json" }

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to eq("The grant_type parameter is required")
      end
    end

    describe "HTTP Basic client authentication" do
      def basic_auth_header(client_id, client_secret)
        encoded = Base64.strict_encode64("#{client_id}:#{client_secret}")
        { "Authorization" => "Basic #{encoded}" }
      end

      let(:client_account) { Account.create!(name: "Test Client Account", email: "client-#{SecureRandom.hex(4)}@example.com") }
      let(:client_secret_value) { "test_secret_#{SecureRandom.hex(8)}" }
      let(:client_app) do
        StandardId::ClientApplication.create!(
          owner: client_account,
          name: "Test Client",
          redirect_uris: "https://example.com/callback",
          scopes: "read write",
          grant_types: "client_credentials authorization_code"
        )
      end
      let(:client_credential) do
        client_app.create_client_secret!(
          name: "Test Client Secret",
          client_secret: client_secret_value
        )
      end

      before do
        identifier = StandardId::EmailIdentifier.create!(
          account: client_account,
          value: "client-cred-#{SecureRandom.hex(4)}@example.com",
          verified_at: Time.current
        )
        StandardId::Credential.create!(
          credentialable: client_credential,
          identifier: identifier
        )
      end

      it "successfully authenticates via Basic auth header" do
        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header(client_app.client_id, client_secret_value),
          as: :json

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["access_token"]).to be_present
        expect(body["token_type"]).to eq("Bearer")
        expect(body["expires_in"]).to be > 0
      end

      it "successfully authenticates via request body" do
        post path,
          params: {
            grant_type: "client_credentials",
            client_id: client_app.client_id,
            client_secret: client_secret_value,
            audience: "test"
          },
          as: :json

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["access_token"]).to be_present
        expect(body["token_type"]).to eq("Bearer")
        expect(body["expires_in"]).to be > 0
      end

      it "returns invalid_client for wrong credentials via Basic auth" do
        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header(client_app.client_id, "wrong-secret"),
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "rejects when credentials are in both header and body" do
        post path,
          params: { grant_type: "client_credentials", client_id: client_app.client_id, client_secret: client_secret_value },
          headers: basic_auth_header(client_app.client_id, client_secret_value),
          as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to include("Authorization header OR request body")
      end

      it "rejects malformed Basic auth encoding" do
        post path,
          params: { grant_type: "client_credentials" },
          headers: { "Authorization" => "Basic !!!invalid-base64!!!" },
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "URL-decodes client credentials per RFC 6749 Section 2.3.1" do
        # Client ID with special chars: "my:client" → URL-encoded as "my%3Aclient"
        encoded_id = CGI.escape("my:client")
        encoded_secret = CGI.escape("secret/with+special=chars")

        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header(encoded_id, encoded_secret),
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "ignores non-Basic Authorization headers" do
        post path,
          params: { grant_type: "client_credentials" },
          headers: { "Authorization" => "Bearer some-token" },
          as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
      end

      it "handles client_secret containing colons" do
        # Secret "pass:word:123" should be split on first colon only
        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header("my-client", "pass:word:123"),
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end
    end

    # describe "grant type validation" do
    #   it "recognizes client_credentials as valid grant type" do
    #     post path, params: { grant_type: "client_credentials" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     # Should fail on missing parameters, not unsupported grant type
    #     expect(response.body).not_to include("unsupported_grant_type")
    #   end

    #   it "recognizes authorization_code as valid grant type" do
    #     post path, params: { grant_type: "authorization_code" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     # Should fail on missing parameters, not unsupported grant type
    #     expect(response.body).not_to include("unsupported_grant_type")
    #   end

    #   it "recognizes password as valid grant type" do
    #     post path, params: { grant_type: "password" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     # Should fail on missing parameters, not unsupported grant type
    #     expect(response.body).not_to include("unsupported_grant_type")
    #   end
    # end

    # describe "response headers" do
    #   it "sets cache headers on error responses" do
    #     post path, params: { grant_type: "invalid" }, as: :json

    #     expect(response.headers["Cache-Control"]).to eq("no-cache")
    #   end

    #   it "sets cache headers on missing grant_type" do
    #     post path, params: {}, as: :json

    #     expect(response.headers["Cache-Control"]).to eq("no-cache")
    #   end
    # end

    # describe "OAuth error format" do
    #   it "returns proper OAuth error structure" do
    #     post path, params: { grant_type: "invalid" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     body = JSON.parse(response.body)
    #     expect(body).to have_key("error")
    #     expect(body).to have_key("error_description")
    #     expect(body["error"]).to be_a(String)
    #     expect(body["error_description"]).to be_a(String)
    #   end

    #   it "uses standard OAuth error codes" do
    #     post path, params: {}, as: :json
    #     body = JSON.parse(response.body)
    #     expect(body["error"]).to eq("invalid_request")

    #     post path, params: { grant_type: "unsupported" }, as: :json
    #     body = JSON.parse(response.body)
    #     expect(body["error"]).to eq("unsupported_grant_type")
    #   end
    # end

    # describe "controller inheritance" do
    #   it "inherits JSON content-type validation from Api::BaseController" do
    #     post path, params: {}, headers: { "CONTENT_TYPE" => "text/plain" }

    #     expect(response).to have_http_status(:bad_request)
    #     body = JSON.parse(response.body)
    #     expect(body["error"]).to eq("invalid_request")
    #     expect(body["error_description"]).to include("Content-Type")
    #   end

    #   it "inherits cache headers from Api::BaseController" do
    #     post path, params: {}, as: :json

    #     expect(response.headers["Cache-Control"]).to eq("no-cache")
    #   end
    # end
  end
end
