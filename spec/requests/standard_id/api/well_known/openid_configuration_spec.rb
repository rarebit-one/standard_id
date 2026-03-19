require "rails_helper"

RSpec.describe "StandardId::Api::WellKnown::OpenidConfigurationController", type: :request do
  let(:path) { api_standard_id_api.well_known_openid_configuration_path }

  describe "GET /.well-known/openid-configuration" do
    context "when issuer is configured" do
      before do
        allow(StandardId.config).to receive(:issuer).and_return("https://auth.example.com")
      end

      it "returns 200 OK" do
        get path
        expect(response).to have_http_status(:ok)
      end

      it "returns JSON content type" do
        get path
        expect(response.content_type).to match(%r{application/json})
      end

      it "sets public cache headers" do
        get path
        expect(response.headers["Cache-Control"]).to eq("public, max-age=3600")
      end

      it "includes the issuer" do
        get path
        body = response.parsed_body
        expect(body["issuer"]).to eq("https://auth.example.com")
      end

      it "includes standard OIDC discovery fields" do
        get path
        body = response.parsed_body

        expect(body["authorization_endpoint"]).to eq("https://auth.example.com/authorize")
        expect(body["token_endpoint"]).to eq("https://auth.example.com/oauth/token")
        expect(body["revocation_endpoint"]).to eq("https://auth.example.com/oauth/revoke")
        expect(body["userinfo_endpoint"]).to eq("https://auth.example.com/userinfo")
        expect(body["jwks_uri"]).to eq("https://auth.example.com/.well-known/jwks.json")
      end

      it "includes supported response types and grant types" do
        get path
        body = response.parsed_body

        expect(body["response_types_supported"]).to eq(["code"])
        expect(body["grant_types_supported"]).to include("authorization_code", "refresh_token")
        expect(body["subject_types_supported"]).to eq(["public"])
      end

      it "includes the signing algorithm" do
        get path
        body = response.parsed_body

        expect(body["id_token_signing_alg_values_supported"]).to be_an(Array)
        expect(body["id_token_signing_alg_values_supported"].first).to be_a(String)
      end

      it "strips trailing slash from issuer in endpoint URLs" do
        allow(StandardId.config).to receive(:issuer).and_return("https://auth.example.com/")

        get path
        body = response.parsed_body

        expect(body["token_endpoint"]).to eq("https://auth.example.com/oauth/token")
      end
    end

    context "when issuer is not configured" do
      before do
        allow(StandardId.config).to receive(:issuer).and_return(nil)
      end

      it "returns 404" do
        get path
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
