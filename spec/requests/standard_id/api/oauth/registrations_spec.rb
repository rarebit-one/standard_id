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

        client = StandardId::ClientApplication.find_by(client_id: body["client_id"])
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
end
