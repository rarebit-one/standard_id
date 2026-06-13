require "rails_helper"

# Change F: HTML consent gate for the interactive authorization-code flow.
#
# An authenticated, interactive (HTML) /authorize for a client with
# require_consent enabled and no prior grant is handed off to the WebEngine
# consent screen instead of issuing a code. On approve a ClientGrant is
# recorded and the code is issued; on deny the user is redirected back with
# error=access_denied; a prior grant skips consent entirely.
RSpec.describe "StandardId OAuth consent flow", type: :request do
  let(:client_owner) { Account.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:client) do
    StandardId::ClientApplication.create!(
      owner: client_owner,
      name: "Consent Client",
      client_id: "consent_client_#{SecureRandom.hex(4)}",
      redirect_uris: "https://example.com/callback",
      scopes: "read write",
      require_consent: true,
      require_pkce: false,
      code_challenge_methods: nil
    )
  end

  let(:account) { Account.create!(name: "Consenter", email: "consenter-#{SecureRandom.hex(4)}@example.com") }

  let(:authorize_params) do
    {
      response_type: "code",
      client_id: client.client_id,
      redirect_uri: "https://example.com/callback",
      scope: "read",
      state: "consent_state_123"
    }
  end

  def sign_in
    session = StandardId::BrowserSession.create!(
      account: account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now
    )
    post util_session_path, params: { session_token: session.token }
  end

  before { sign_in }

  describe "GET /api/authorize for a require_consent client" do
    it "redirects to the consent screen instead of issuing a code" do
      http_get "/api/authorize", params: authorize_params

      expect(response).to have_http_status(:found)
      expect(response.location).to include("/consent")
      expect(response.location).to include("consent_request=")
      expect(response.location).not_to include("code=")
    end

    it "rejects an unregistered redirect_uri rather than handing it to consent (no open redirect on deny)" do
      http_get "/api/authorize", params: authorize_params.merge(redirect_uri: "https://evil.example.com/callback")

      # Must NOT 302 to /consent — that would sign the unvalidated redirect_uri
      # into the consent payload and let the Deny path redirect off-host.
      expect(response.location.to_s).not_to include("/consent")
      expect(response.location.to_s).not_to include("evil.example.com")
      body = JSON.parse(response.body) rescue {}
      expect(body["error_description"].to_s).to include("Invalid redirect_uri")
    end

    it "renders the consent screen with client name and scopes" do
      http_get "/api/authorize", params: authorize_params
      consent_url = response.location

      get consent_url
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(client.name)
      expect(response.body).to include("read")
      expect(response.body).to include("Approve")
      expect(response.body).to include("Deny")
    end
  end

  describe "POST /consent" do
    def consent_request_token
      http_get "/api/authorize", params: authorize_params
      uri = URI.parse(response.location)
      Rack::Utils.parse_query(uri.query)["consent_request"]
    end

    it "approve issues an authorization code and records a grant" do
      token = consent_request_token

      expect {
        http_post "/consent", params: { decision: "approve", consent_request: token }
      }.to change(StandardId::ClientGrant, :count).by(1)

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://example.com/callback")
      expect(response.location).to include("code=")
      expect(response.location).to include("state=consent_state_123")

      grant = StandardId::ClientGrant.last
      expect(grant.account_id).to eq(account.id)
      expect(grant.client_id).to eq(client.client_id)
    end

    it "deny redirects to redirect_uri with error=access_denied and state" do
      token = consent_request_token

      expect {
        http_post "/consent", params: { decision: "deny", consent_request: token }
      }.not_to change(StandardId::ClientGrant, :count)

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://example.com/callback")
      expect(response.location).to include("error=access_denied")
      expect(response.location).to include("state=consent_state_123")
      expect(response.location).not_to include("code=")
    end

    it "rejects a tampered/invalid consent payload" do
      http_post "/consent", params: { decision: "approve", consent_request: "not-a-valid-token" }
      expect(response).to have_http_status(:bad_request)
    end

    # NOTE: when the consent screen is Inertia-rendered (host app sets
    # use_inertia), the decision arrives as an Inertia XHR, which cannot follow
    # a 302 to the external client redirect_uri. ConsentController#redirect_out
    # then emits an Inertia-Location (409 + X-Inertia-Location) instead. That
    # branch can only run where inertia_rails is loaded — this gem has no
    # inertia_rails dependency, so the Inertia path is covered by the consuming
    # app's integration test (sidekick-web: mcp_authorization_flow_spec).
  end

  describe "with a prior grant" do
    before do
      StandardId::ClientGrant.record!(account: account, client_id: client.client_id, scope: "read write")
    end

    it "skips consent and issues a code directly" do
      http_get "/api/authorize", params: authorize_params

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://example.com/callback")
      expect(response.location).to include("code=")
      expect(response.location).not_to include("/consent")
    end
  end
end
