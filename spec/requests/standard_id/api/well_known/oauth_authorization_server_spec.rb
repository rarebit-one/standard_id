require "rails_helper"

# Change B/C: RFC 8414 OAuth 2.0 Authorization Server Metadata, sharing the
# DiscoveryDocument builder with the OIDC discovery document.
RSpec.describe "StandardId::Api::WellKnown::OauthAuthorizationServerController", type: :request do
  describe "GET /.well-known/oauth-authorization-server" do
    context "when issuer is configured" do
      before do
        allow(StandardId.config).to receive(:issuer).and_return("https://auth.example.com")
      end

      it "returns 200 OK with JSON" do
        get "/api/.well-known/oauth-authorization-server"
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to match(%r{application/json})
      end

      it "sets public cache headers" do
        get "/api/.well-known/oauth-authorization-server"
        expect(response.headers["Cache-Control"]).to include("public").and include("max-age=3600")
      end

      it "includes the issuer and core endpoints" do
        get "/api/.well-known/oauth-authorization-server"
        body = response.parsed_body

        expect(body["issuer"]).to eq("https://auth.example.com")
        expect(body["authorization_endpoint"]).to eq("https://auth.example.com/authorize")
        expect(body["token_endpoint"]).to eq("https://auth.example.com/oauth/token")
        expect(body["revocation_endpoint"]).to eq("https://auth.example.com/oauth/revoke")
        expect(body["jwks_uri"]).to eq("https://auth.example.com/.well-known/jwks.json")
      end

      it "advertises PKCE S256 (change C)" do
        get "/api/.well-known/oauth-authorization-server"
        expect(response.parsed_body["code_challenge_methods_supported"]).to eq(["S256"])
      end

      it "does not advertise a registration_endpoint when DCR is disabled (default)" do
        allow(StandardId.config.oauth).to receive(:dynamic_registration_enabled).and_return(false)
        get "/api/.well-known/oauth-authorization-server"
        expect(response.parsed_body).not_to have_key("registration_endpoint")
      end

      it "advertises a registration_endpoint when DCR is enabled (change D)" do
        allow(StandardId.config.oauth).to receive(:dynamic_registration_enabled).and_return(true)
        get "/api/.well-known/oauth-authorization-server"
        expect(response.parsed_body["registration_endpoint"]).to eq("https://auth.example.com/oauth/register")
      end
    end

    context "when issuer is not configured" do
      before do
        allow(StandardId.config).to receive(:issuer).and_return(nil)
      end

      it "returns 404" do
        get "/api/.well-known/oauth-authorization-server"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "parity with openid-configuration" do
    before do
      allow(StandardId.config).to receive(:issuer).and_return("https://auth.example.com")
    end

    it "shares identical values for all overlapping keys" do
      get "/api/.well-known/oauth-authorization-server"
      as_metadata = response.parsed_body

      get "/api/.well-known/openid-configuration"
      oidc = response.parsed_body

      overlapping = as_metadata.keys & oidc.keys
      expect(overlapping).to include("issuer", "authorization_endpoint", "token_endpoint", "code_challenge_methods_supported")
      overlapping.each do |key|
        expect(as_metadata[key]).to eq(oidc[key]), "expected #{key} to match across both documents"
      end
    end
  end
end
