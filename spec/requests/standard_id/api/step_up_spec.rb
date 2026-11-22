require "rails_helper"

# ApiAuthentication#require_recent_authentication! and POST /step_up,
# /step_up/verify (StandardId::StepUp). The dummy app's
# Api::V1::SensitiveController is guarded with `within: 5.minutes`.
RSpec.describe "API step-up authentication", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:email) { "api-step-up-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "Sup3r-secret!" }
  let(:token_path) { "/api/oauth/token" }
  let!(:account) { create_account_with_password(email: email, password: password) }

  before do
    StandardId.config.step_up.enabled = true
    capture_passwordless_codes
  end

  def json = JSON.parse(response.body)

  def password_grant!
    post token_path, params: { grant_type: "password", username: email, password: password, client_id: "test-client", scope: "read" }, as: :json
    expect(response).to have_http_status(:ok)
    json
  end

  def claims(token)
    StandardId::JwtService.decode(token)
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def get_sensitive(token)
    get "/api/v1/sensitive", headers: bearer(token)
  end

  def step_up_post(path, token, params = {})
    post path, params: params, headers: bearer(token), as: :json
  end

  describe "auth_time on access tokens" do
    it "is the time of a password grant" do
      freeze_time do
        expect(claims(password_grant!["access_token"])[:auth_time]).to eq(Time.current.to_i)
      end
    end

    it "is recorded on the refresh token and carried, unchanged, through a refresh" do
      signed_in_at = Time.current.change(usec: 0)
      tokens = travel_to(signed_in_at) { password_grant! }
      record = StandardId::RefreshToken.find_by_jti(claims(tokens["refresh_token"])[:jti])
      expect(record.authenticated_at).to eq(signed_in_at)

      travel 1.hour
      post token_path, params: { grant_type: "refresh_token", refresh_token: tokens["refresh_token"], client_id: "test-client" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(claims(json["access_token"])[:auth_time]).to eq(signed_in_at.to_i)
      expect(StandardId::RefreshToken.find_by_jti(claims(json["refresh_token"])[:jti]).authenticated_at).to eq(signed_in_at)
    end

    it "comes from the browser session through /authorize and the authorization_code grant" do
      redirect_uri = "https://client.example.com/callback"
      verifier = "verifier-#{SecureRandom.hex(24)}"
      client = StandardId::ClientApplication.create!(
        owner: account, name: "Step-up Client", redirect_uris: redirect_uri, scopes: "read",
        grant_types: "authorization_code refresh_token", response_types: "code",
        client_type: "public", require_pkce: true, code_challenge_methods: "S256", require_consent: false
      )
      signed_in_at = Time.current.change(usec: 0)
      travel_to(signed_in_at) { http_post "/login", params: { login: { email: email, password: password } } }

      travel 2.minutes
      http_get "/api/authorize", params: {
        response_type: "code", client_id: client.client_id, redirect_uri: redirect_uri, scope: "read", state: "s",
        code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("="), code_challenge_method: "S256"
      }
      code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]
      post token_path, params: { grant_type: "authorization_code", client_id: client.client_id, code: code, redirect_uri: redirect_uri, code_verifier: verifier }, as: :json

      expect(response).to have_http_status(:ok)
      expect(claims(json["access_token"])[:auth_time]).to eq(signed_in_at.to_i)
    end

    it "is absent from a direct mint that names no time, and a host claim cannot override the one it names" do
      minted = StandardId::TokenMinter.mint(account: account, audience: nil, grant_type: "harness.mint")
      expect(claims(minted.access_token)).not_to have_key(:auth_time)

      stamped = StandardId::TokenMinter.mint(account: account, audience: nil, grant_type: "harness.mint",
        authenticated_at: 1.minute.ago, claims: { auth_time: 1.minute.from_now.to_i })
      expect(claims(stamped.access_token)[:auth_time]).to eq(1.minute.ago.to_i)
    end

    it "cannot be supplied by a claim when no time was recorded" do
      minted = StandardId::TokenMinter.mint(account: account, audience: nil, grant_type: "harness.mint",
        claims: { auth_time: Time.current.to_i })
      expect(claims(minted.access_token)).not_to have_key(:auth_time)

      StandardId.config.oauth.custom_claims = ->(**) { { "auth_time" => Time.current.to_i } }
      client_token = StandardId::TokenMinter.mint(account: account, audience: nil, grant_type: "harness.mint")
      expect(claims(client_token.access_token)).not_to have_key(:auth_time)
    end

    it "is not minted while c.step_up.enabled is false" do
      StandardId.config.step_up.enabled = false

      expect(claims(password_grant!["access_token"])).not_to have_key(:auth_time)
    end
  end

  describe "require_recent_authentication!" do
    it "lets a fresh token through" do
      get_sensitive(password_grant!["access_token"])

      expect(response).to have_http_status(:ok)
      expect(json).to eq("account" => account.id)
    end

    it "answers a stale token with RFC 9470's insufficient_user_authentication challenge" do
      token = password_grant!["access_token"]
      travel 10.minutes
      get_sensitive(token)

      expect(response).to have_http_status(:unauthorized)
      expect(json).to include("error" => "insufficient_user_authentication", "max_age" => 300)
      expect(response.headers["WWW-Authenticate"]).to include('error="insufficient_user_authentication"').and include("max_age=300")
    end

    it "answers a token without auth_time the same way" do
      get_sensitive(StandardId::JwtService.encode({ sub: account.id, client_id: "test-client", scope: "read" }))

      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to eq("insufficient_user_authentication")
    end

    it "still answers a missing token as unauthenticated, not as a step-up" do
      get "/api/v1/sensitive"

      # The dummy host's own NotAuthenticatedError handler.
      expect(response).to redirect_to(%r{/login})
      expect(response.headers["WWW-Authenticate"]).to be_nil
    end
  end

  describe "the step-up endpoints" do
    let!(:tokens) { password_grant! }
    let(:stale_token) { tokens["access_token"] }

    before { travel 10.minutes }

    it "issues a code and says whether the password is needed" do
      step_up_post("/api/step_up", stale_token)

      expect(response).to have_http_status(:accepted)
      expect(json).to eq("channel" => "email", "password_required" => true)
      expect(issued_otp_code(email)).to be_present
    end

    it "returns a fresh token that passes the guard, keeping client_id and scope" do
      step_up_post("/api/step_up", stale_token)
      step_up_post("/api/step_up/verify", stale_token, code: issued_otp_code(email), password: password)

      expect(response).to have_http_status(:ok)
      expect(json).not_to have_key("refresh_token")
      fresh = json["access_token"]
      expect(claims(fresh)).to include(sub: account.id, client_id: "test-client", scope: "read", grant_type: "step_up", auth_time: Time.current.to_i)

      get_sensitive(fresh)
      expect(response).to have_http_status(:ok)
    end

    it "re-mints for the profile c.step_up.token_profile_resolver names" do
      seen = nil
      StandardId.config.step_up.token_profile_resolver = ->(account:, claims:) { seen = [account.id, claims[:client_id]]; nil }
      allow(StandardId::TokenMinter).to receive(:mint).and_call_original

      step_up_post("/api/step_up", stale_token)
      step_up_post("/api/step_up/verify", stale_token, code: issued_otp_code(email), password: password)

      expect(response).to have_http_status(:ok)
      expect(seen).to eq([account.id, "test-client"])
      expect(StandardId::TokenMinter).to have_received(:mint).with(hash_including(profile: nil, grant_type: "step_up"))
    end

    it "refuses a wrong code or password with 422 and no token" do
      step_up_post("/api/step_up", stale_token)
      step_up_post("/api/step_up/verify", stale_token, code: issued_otp_code(email), password: "Wr0ng-password!")

      expect(response).to have_http_status(:unprocessable_content)
      expect(json).to include("error" => "invalid_password")
      expect(json).not_to have_key("access_token")
    end

    it "needs a valid access token" do
      post "/api/step_up", params: {}, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to eq("invalid_token")
    end

    it "refuses a token whose account account_scope no longer finds" do
      StandardId.config.account_scope = ->(scope) { scope.where.not(id: account.id) }
      step_up_post("/api/step_up", stale_token)

      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to eq("invalid_token")
    end

    it "is not drawn while c.step_up.enabled is false" do
      StandardId.config.step_up.enabled = false
      step_up_post("/api/step_up", stale_token)

      expect(response).to have_http_status(:not_found)
    end
  end
end
