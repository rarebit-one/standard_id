require "rails_helper"

# Change D: RFC 7591 Dynamic Client Registration behind a default-off toggle.
RSpec.describe "StandardId::Api::Oauth::RegistrationsController", type: :request do
  let(:path) { "/api/oauth/register" }

  let(:owner) do
    Account.create!(name: "DCR Owner", email: "dcr-owner-#{SecureRandom.hex(4)}@example.com")
  end

  def enable_dcr!(resolver)
    allow(StandardId.config.oauth).to receive(:dynamic_registration_enabled).and_return(true)
    allow(StandardId.config.oauth).to receive(:dynamic_registration_owner).and_return(resolver)
  end

  describe "POST /api/oauth/register" do
    context "when dynamic registration is disabled (default)" do
      before do
        allow(StandardId.config.oauth).to receive(:dynamic_registration_enabled).and_return(false)
      end

      it "returns 404 — the endpoint is fully absent" do
        post path, params: { redirect_uris: ["https://app.example.com/cb"] }, as: :json
        expect(response).to have_http_status(:not_found)
      end

      it "does not create a client application" do
        expect do
          post path, params: { redirect_uris: ["https://app.example.com/cb"] }, as: :json
        end.not_to change(StandardId::ClientApplication, :count)
      end
    end

    context "when dynamic registration is enabled" do
      let(:resolver) { -> { owner } }

      before { enable_dcr!(resolver) }

      it "registers a public client (201) with PKCE/S256/consent defaults" do
        post path,
          params: {
            client_name: "My MCP Client",
            redirect_uris: ["https://app.example.com/callback"]
          },
          as: :json

        expect(response).to have_http_status(:created)
        body = response.parsed_body

        expect(body["client_id"]).to be_present
        expect(body["client_id_issued_at"]).to be_a(Integer)
        expect(body["client_name"]).to eq("My MCP Client")
        expect(body["redirect_uris"]).to eq(["https://app.example.com/callback"])
        expect(body["token_endpoint_auth_method"]).to eq("none")
        expect(body["scope"]).to eq("openid profile email")
        # public client => no secret in the response
        expect(body).not_to have_key("client_secret")

        client = StandardId::ClientApplication.includes(:owner).find_by(client_id: body["client_id"])
        expect(client.client_type).to eq("public")
        expect(client.require_pkce).to be(true)
        expect(client.code_challenge_methods_array).to eq(["S256"])
        expect(client.require_consent).to be(true)
        expect(client.owner).to eq(owner)
      end

      it "generates a name when client_name is absent" do
        post path, params: { redirect_uris: ["https://app.example.com/cb"] }, as: :json

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["client_name"]).to be_present
      end

      it "registers a confidential client and returns a one-time secret" do
        post path,
          params: {
            client_name: "Server Client",
            redirect_uris: ["https://server.example.com/cb"],
            token_endpoint_auth_method: "client_secret_basic"
          },
          as: :json

        expect(response).to have_http_status(:created)
        body = response.parsed_body

        expect(body["client_secret"]).to be_present
        expect(body["client_secret_expires_at"]).to eq(0)

        client = StandardId::ClientApplication.find_by(client_id: body["client_id"])
        expect(client.client_type).to eq("confidential")
        expect(client.primary_client_secret).to be_present
      end

      it "echoes the registered token_endpoint_auth_method (RFC 7591 §3.2.1)" do
        post path,
          params: {
            client_name: "Post Client",
            redirect_uris: ["https://post.example.com/cb"],
            token_endpoint_auth_method: "client_secret_post"
          },
          as: :json

        expect(response).to have_http_status(:created)
        # Must echo what was registered, not a value derived from client_type.
        expect(response.parsed_body["token_endpoint_auth_method"]).to eq("client_secret_post")
      end

      it "rejects a missing redirect_uris with invalid_redirect_uri (400)" do
        post path, params: { client_name: "No Redirect" }, as: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("invalid_redirect_uri")
      end

      it "rejects an invalid redirect_uri with invalid_redirect_uri (400)" do
        post path, params: { redirect_uris: ["not-a-valid-uri"] }, as: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("invalid_redirect_uri")
      end

      it "rejects a disallowed grant_type with invalid_client_metadata (400)" do
        post path,
          params: {
            redirect_uris: ["https://app.example.com/cb"],
            grant_types: ["authorization_code", "client_credentials"]
          },
          as: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
      end

      context "when the owner resolver is nil" do
        let(:resolver) { nil }

        it "raises a clear configuration error" do
          expect do
            post path, params: { redirect_uris: ["https://app.example.com/cb"] }, as: :json
          end.to raise_error(StandardId::ConfigurationError, /dynamic_registration_owner/)
        end
      end
    end
  end

  describe "RFC 7592 client-configuration endpoint" do
    let(:resolver) { -> { owner } }

    before do
      enable_dcr!(resolver)
      allow(StandardId.config.oauth).to receive(:dynamic_registration_attributes).and_return(scopes: %w[mcp mcp:read])
    end

    def register!
      post path, params: { client_name: "Managed", redirect_uris: ["https://app.example.com/cb"] }, as: :json
      expect(response).to have_http_status(:created)
      response.parsed_body
    end

    # GET and DELETE are sent the way a client sends them: no body, no
    # Content-Type. Only PUT carries a JSON document.
    def manage(verb, client_id, token: nil, params: nil)
      headers = token ? { "Authorization" => "Bearer #{token}" } : {}
      if params.nil?
        send(verb, "#{path}/#{client_id}", headers: headers)
      else
        send(verb, "#{path}/#{client_id}", params: params, headers: headers, as: :json)
      end
    end

    it "returns registration_client_uri and a one-time registration_access_token at registration" do
      body = register!
      expect(body["registration_access_token"]).to be_present
      expect(body["registration_client_uri"]).to eq("http://www.example.com/api/oauth/register/#{body['client_id']}")
      expect(body["scope"]).to eq("mcp mcp:read")
    end

    it "reads, updates and deregisters the client with its token" do
      body = register!
      client_id = body["client_id"]
      token = body["registration_access_token"]

      manage(:get, client_id, token: token)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("client_id" => client_id, "client_name" => "Managed", "registration_client_uri" => body["registration_client_uri"])
      expect(response.parsed_body).not_to have_key("registration_access_token")

      manage(:put, client_id, token: token, params: { client_id: client_id, client_name: "Renamed", redirect_uris: ["https://app.example.com/cb2"], scope: "openid" })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("client_name" => "Renamed", "redirect_uris" => ["https://app.example.com/cb2"], "scope" => "mcp mcp:read")

      manage(:delete, client_id, token: token)
      expect(response).to have_http_status(:no_content)
      expect(StandardId::ClientApplication.find_by(client_id: client_id)).not_to be_active

      manage(:get, client_id, token: token)
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s a missing token (bare challenge), a wrong token, and an unknown or non-dynamic client alike" do
      body = register!
      client_id = body["client_id"]

      manage(:get, client_id)
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq("Bearer")

      manage(:get, client_id, token: "wrong")
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq(%(Bearer error="invalid_token"))
      expect(response.parsed_body["error"]).to eq("invalid_token")

      manage(:get, "nope", token: body["registration_access_token"])
      expect(response).to have_http_status(:unauthorized)

      static = StandardId::ClientApplication.create!(owner: owner, name: "Static", client_id: "static_client",
        redirect_uris: "https://app.example.com/cb", scopes: "read")
      manage(:get, static.client_id, token: body["registration_access_token"])
      expect(response).to have_http_status(:unauthorized)
    end

    it "renders a 400 RFC 7591 error for an invalid update, including a document whose client_id is another client's" do
      body = register!
      manage(:put, body["client_id"], token: body["registration_access_token"], params: { redirect_uris: ["not a uri"] })
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_redirect_uri")

      manage(:put, body["client_id"], token: body["registration_access_token"], params: { client_id: "someone_else", redirect_uris: ["https://app.example.com/cb"] })
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
      expect(response.parsed_body["error_description"]).to include("client_id")
    end

    it "is absent while dynamic registration is disabled" do
      body = register!
      allow(StandardId.config.oauth).to receive(:dynamic_registration_enabled).and_return(false)
      manage(:get, body["client_id"], token: body["registration_access_token"])
      expect(response).to have_http_status(:not_found)
    end
  end
end
