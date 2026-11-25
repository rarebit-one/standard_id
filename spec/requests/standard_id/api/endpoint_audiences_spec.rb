require "rails_helper"

# oauth.endpoint_audiences narrows the audiences the gem's own bearer endpoints
# (userinfo, sessions, step_up) accept, below the accepted list. The shape it
# exists for: an app that accepts end-user client tokens (companion_kit,
# admin_kit) and per-service or MCP tokens (harness, inference, mcp) on its API,
# but serves the account's own data only to the end-user clients.
RSpec.describe "Per-endpoint accepted audiences", type: :request do
  let(:email) { "endpoint-aud-#{SecureRandom.hex(4)}@example.com" }
  let!(:account) { create_account_with_password(email: email, password: "Sup3r-secret!") }
  let(:oauth) { StandardId.config.oauth }
  let(:client_audiences) { %w[companion_kit admin_kit] }
  let(:other_audiences) { %w[harness inference mcp] }

  before do
    allow(oauth).to receive(:allowed_audiences).and_return(client_audiences + other_audiences)
    StandardId.config.step_up.enabled = true
    capture_passwordless_codes
  end

  def token_for(aud)
    StandardId::JwtService.encode({ sub: account.id, client_id: "test-client", scope: "read", aud: aud })
  end

  def bearer(aud)
    { "Authorization" => "Bearer #{token_for(aud)}" }
  end

  def expect_insufficient_scope
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq(
      "error" => "insufficient_scope",
      "error_description" => StandardId::AudienceVerification::GENERIC_INSUFFICIENT_SCOPE_MESSAGE
    )
    expect(response.headers["WWW-Authenticate"]).to include('error="insufficient_scope"')
  end

  context "when endpoint_audiences restricts every endpoint to the client audiences" do
    before do
      allow(oauth).to receive(:endpoint_audiences).and_return(
        userinfo: client_audiences, sessions: client_audiences, step_up: client_audiences
      )
    end

    %w[companion_kit admin_kit].each do |aud|
      it "serves GET /userinfo to an #{aud} token" do
        get "/api/userinfo", headers: bearer(aud)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["sub"]).to eq(account.id.to_s)
      end

      it "serves GET /sessions to an #{aud} token" do
        get "/api/sessions", headers: bearer(aud)

        expect(response).to have_http_status(:ok)
      end

      it "starts a step-up for an #{aud} token" do
        post "/api/step_up", headers: bearer(aud), as: :json

        expect(response).to have_http_status(:accepted)
      end
    end

    %w[harness inference mcp].each do |aud|
      it "refuses GET /userinfo to an #{aud} token with 403" do
        get "/api/userinfo", headers: bearer(aud)

        expect_insufficient_scope
      end

      it "refuses GET /sessions to an #{aud} token with 403" do
        get "/api/sessions", headers: bearer(aud)

        expect_insufficient_scope
      end

      it "refuses DELETE /sessions/:id to an #{aud} token with 403 and revokes nothing" do
        session = StandardId::BrowserSession.create!(
          account: account, ip_address: "127.0.0.1", user_agent: "spec", expires_at: 1.day.from_now
        )

        delete "/api/sessions/#{session.id}", headers: bearer(aud)

        expect_insufficient_scope
        expect(session.reload.revoked_at).to be_nil
      end

      it "refuses POST /step_up and /step_up/verify to an #{aud} token with 403" do
        post "/api/step_up", headers: bearer(aud), as: :json
        expect_insufficient_scope

        post "/api/step_up/verify", params: { code: "000000" }, headers: bearer(aud), as: :json
        expect_insufficient_scope
      end
    end

    it "refuses a token with no aud claim at decode time (401) while an accepted list is set" do
      get "/api/userinfo", headers: bearer(nil)

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a token with no aud claim with 403 when nothing is checked at decode time" do
      allow(oauth).to receive(:accepted_audiences).and_return([])

      get "/api/userinfo", headers: bearer(nil)

      expect_insufficient_scope
    end

    it "restricts the endpoints even when nothing is checked at decode time" do
      allow(oauth).to receive(:accepted_audiences).and_return([])

      get "/api/sessions", headers: bearer("billing")

      expect_insufficient_scope
    end

    it "refuses an array aud with none of the endpoint's audiences" do
      get "/api/sessions", headers: bearer(%w[harness inference])

      expect_insufficient_scope
    end

    it "accepts an array aud that carries one of the endpoint's audiences, as AudienceVerification does" do
      get "/api/sessions", headers: bearer(%w[harness companion_kit])

      expect(response).to have_http_status(:ok)
    end

    it "still answers 401 for a missing token, not 403" do
      get "/api/userinfo"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("invalid_token")
    end

    it "still answers 401 for a token outside the accepted audiences" do
      get "/api/userinfo", headers: bearer("billing")

      expect(response).to have_http_status(:unauthorized)
    end

    it "applies the matched audience's audience_profile_types binding, as on any AudienceVerification controller" do
      allow(oauth).to receive(:audience_profile_types).and_return("companion_kit" => "DeviceUserProfile")

      get "/api/userinfo", headers: bearer("companion_kit")

      expect_insufficient_scope
    end
  end

  context "when only some endpoints are listed" do
    before { allow(oauth).to receive(:endpoint_audiences).and_return("userinfo" => %w[companion_kit]) }

    it "restricts the listed endpoint (string keys work too)" do
      get "/api/userinfo", headers: bearer("admin_kit")

      expect_insufficient_scope
    end

    it "leaves the others open to any accepted audience" do
      get "/api/sessions", headers: bearer("mcp")

      expect(response).to have_http_status(:ok)
    end
  end

  context "when an endpoint is given an empty list" do
    before { allow(oauth).to receive(:endpoint_audiences).and_return(userinfo: []) }

    it "treats it as unset" do
      get "/api/userinfo", headers: bearer("harness")

      expect(response).to have_http_status(:ok)
    end
  end

  context "when endpoint_audiences is unset (default)" do
    it "is empty" do
      expect(oauth.endpoint_audiences).to eq({})
    end

    %w[companion_kit admin_kit harness inference mcp].each do |aud|
      it "serves /userinfo, /sessions and /step_up to an #{aud} token, as before" do
        get "/api/userinfo", headers: bearer(aud)
        expect(response).to have_http_status(:ok)

        get "/api/sessions", headers: bearer(aud)
        expect(response).to have_http_status(:ok)

        post "/api/step_up", headers: bearer(aud), as: :json
        expect(response).to have_http_status(:accepted)
      end
    end

    it "serves an array aud, as before" do
      get "/api/sessions", headers: bearer(%w[harness inference])

      expect(response).to have_http_status(:ok)
    end
  end
end
