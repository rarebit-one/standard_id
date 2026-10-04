require "rails_helper"

# The refresh_token grant re-checks config.login_method_policy with the method
# of the ORIGINAL authentication, carried along StandardId::AuthLineage:
# web sign-in → BrowserSession metadata → AuthorizationCode metadata →
# RefreshToken#auth_method/auth_provider → each rotated successor.
RSpec.describe "config.login_method_policy on the refresh_token grant", type: :request do
  let(:email) { "lineage-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "s3cureP@ss" }
  let(:token_path) { "/api/oauth/token" }
  let(:redirect_uri) { "https://client.example.com/callback" }
  let(:code_verifier) { "verifier-#{SecureRandom.hex(24)}" }

  let!(:account) { create_account_with_password(email: email, password: password) }

  def json = JSON.parse(response.body)

  def with_policy(policy)
    allow(StandardId.config).to receive(:login_method_policy).and_return(policy)
  end

  def refresh!(refresh_token, client_id:)
    post token_path, params: { grant_type: "refresh_token", refresh_token: refresh_token, client_id: client_id }, as: :json
  end

  def record_for(refresh_token)
    StandardId::RefreshToken.find_by_jti(StandardId::JwtService.decode(refresh_token)[:jti])
  end

  def capture_denied_events
    events = []
    subscription = StandardId::Events.subscribe(StandardId::Events::AUTHENTICATION_METHOD_DENIED) { |event| events << event }
    yield
    events
  ensure
    StandardId::Events.unsubscribe(subscription)
  end

  def password_grant_tokens!
    post token_path, params: { grant_type: "password", username: email, password: password, client_id: "test-client" }, as: :json
    expect(response).to have_http_status(:ok)
    json
  end

  describe "lineage" do
    it "records the method on tokens from the password grant and copies it on rotation" do
      tokens = password_grant_tokens!
      first = record_for(tokens["refresh_token"])
      expect(first).to have_attributes(auth_method: "password", auth_provider: nil)

      refresh!(tokens["refresh_token"], client_id: "test-client")
      expect(response).to have_http_status(:ok)
      expect(record_for(json["refresh_token"])).to have_attributes(auth_method: "password", auth_provider: nil)
    end

    it "records social + provider on tokens from the API social callback" do
      allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
      allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
        { user_info: { "email" => "social-#{email}", "email_verified" => true, "sub" => "g-#{SecureRandom.hex(4)}" }, tokens: {} }.with_indifferent_access
      )

      post "/api/oauth/callback/google", params: { code: "c" }

      expect(response).to have_http_status(:ok)
      expect(record_for(json["refresh_token"])).to have_attributes(auth_method: "social", auth_provider: "google")
    end

    it "carries the web sign-in method through /authorize and the authorization_code grant" do
      client = StandardId::ClientApplication.create!(
        owner: account, name: "Lineage Client", redirect_uris: redirect_uri, scopes: "read",
        grant_types: "authorization_code refresh_token", response_types: "code",
        client_type: "public", require_pkce: true, code_challenge_methods: "S256", require_consent: false
      )

      http_post "/login", params: { login: { email: email, password: password } }
      expect(StandardId::BrowserSession.last.metadata).to include("auth_method" => "password")

      http_get "/api/authorize", params: {
        response_type: "code", client_id: client.client_id, redirect_uri: redirect_uri, scope: "read", state: "s",
        code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier)).delete("="), code_challenge_method: "S256"
      }
      expect(response).to have_http_status(:found)
      code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]
      expect(StandardId::AuthorizationCode.last.metadata).to include("auth_method" => "password")

      post token_path, params: { grant_type: "authorization_code", client_id: client.client_id, code: code, redirect_uri: redirect_uri, code_verifier: code_verifier }, as: :json
      expect(response).to have_http_status(:ok)
      tokens = json
      expect(record_for(tokens["refresh_token"])).to have_attributes(auth_method: "password")

      seen = nil
      with_policy(->(auth_method:, flow:) { seen = [auth_method, flow] })
      refresh!(tokens["refresh_token"], client_id: client.client_id)

      expect(response).to have_http_status(:ok)
      expect(seen).to eq([:password, :oauth_refresh_token])
    end
  end

  describe "refusal" do
    let(:deny_password) do
      ->(auth_method:) { auth_method != :password || raise(StandardId::LoginMethodDenied, "Use the org IdP") }
    end

    it "answers invalid_grant, revokes the whole family and audits the real reason" do
      tokens = password_grant_tokens!
      refresh!(tokens["refresh_token"], client_id: "test-client") # rotate once so there is a family
      current = json["refresh_token"]
      with_policy(deny_password)

      events = capture_denied_events { refresh!(current, client_id: "test-client") }

      expect(response).to have_http_status(:bad_request)
      expect(json).to eq("error" => "invalid_grant", "error_description" => "Refresh token is no longer valid")
      expect(StandardId::RefreshToken.where(account_id: account.id).active).to be_empty
      expect(events.size).to eq(1)
      expect(events.first[:flow]).to eq("oauth_refresh_token")
      expect(events.first[:auth_method]).to eq("password")
      expect(events.first[:error_message]).to eq("Use the org IdP")
    end

    it "does not consult the policy for a token that is already dead" do
      tokens = password_grant_tokens!
      record_for(tokens["refresh_token"]).revoke!
      with_policy(->(**) { raise "must not be called" })

      refresh!(tokens["refresh_token"], client_id: "test-client")

      expect(response).to have_http_status(:bad_request)
      expect(json["error"]).to eq("invalid_grant")
    end
  end

  describe "tokens minted before 0.45 (no recorded method)" do
    let!(:tokens) { password_grant_tokens! }

    before { record_for(tokens["refresh_token"]).update_columns(auth_method: nil, auth_provider: nil) }

    it "still refresh when no policy is configured" do
      refresh!(tokens["refresh_token"], client_id: "test-client")

      expect(response).to have_http_status(:ok)
    end

    it "reach the policy as :unspecified, so a restrictive policy refuses them (fails closed)" do
      seen = nil
      with_policy(->(auth_method:, provider:) { seen = [auth_method, provider]; auth_method == :social && provider == "org_idp" })

      refresh!(tokens["refresh_token"], client_id: "test-client")

      expect(seen).to eq([:unspecified, nil])
      expect(response).to have_http_status(:bad_request)
      expect(json["error"]).to eq("invalid_grant")
    end
  end
end
