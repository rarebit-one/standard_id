require "rails_helper"

RSpec.describe "Global allowed_audiences enforcement", type: :request do
  let(:account) { Account.create!(name: "Test User", email: "audiences-#{SecureRandom.hex(4)}@example.com") }

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

  describe "GET /api/sessions (protected API endpoint)" do
    context "when config.oauth.allowed_audiences is set to %w[web]" do
      before { allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[web]) }

      it "accepts a token whose aud matches" do
        token = StandardId::JwtService.encode({
          sub: account.id,
          client_id: "test-client",
          scope: "read",
          aud: "web"
        })

        get "/api/sessions", headers: bearer(token)

        expect(response).to have_http_status(:ok)
      end

      it "responds 401 (not 500) for a wrong-audience token" do
        token = StandardId::JwtService.encode({
          sub: account.id,
          client_id: "test-client",
          scope: "read",
          aud: "other-service"
        })

        get "/api/sessions", headers: bearer(token)

        expect(response).to have_http_status(:unauthorized)
        body = response.parsed_body
        expect(body["error"]).to eq("invalid_token")
        expect(response.headers["WWW-Authenticate"]).to include("Bearer")
      end

      it "responds 401 for a token with no aud claim" do
        token = StandardId::JwtService.encode({
          sub: account.id,
          client_id: "test-client",
          scope: "read"
        })

        get "/api/sessions", headers: bearer(token)

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when config.oauth.allowed_audiences is empty (default)" do
      before { allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return([]) }

      it "accepts a token with an arbitrary aud (back-compat)" do
        token = StandardId::JwtService.encode({
          sub: account.id,
          client_id: "test-client",
          scope: "read",
          aud: "other-service"
        })

        get "/api/sessions", headers: bearer(token)

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
