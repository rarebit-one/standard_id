require "rails_helper"

# End to end: sign in → sign out → sign in → refresh, on an app that
# materialises a DeviceSession for OAuth grants.
#
# Regression: OauthSessionPersistence.upsert_device_session! looked the device's
# row up with a bare find_by(account:, device_id:), so the second sign-in reused
# the row sign-out had revoked. Every refresh token minted after that pointed at
# a revoked parent, and RefreshTokenFlow#validate_parent_session! refused the
# first refresh — the client was sent back to sign-in each time its access token
# expired, on every device, forever (sidekick-web's companion app; patched
# host-side in config/initializers/standard_id_device_session_upsert.rb).
RSpec.describe "Signing in again after signing out (device sessions)", type: :request do
  let(:token_path) { api_standard_id_api.oauth_token_path }
  let(:account) { Account.create!(name: "Companion User", email: "companion-#{SecureRandom.hex(4)}@example.com") }
  let(:redirect_uri) { "https://app.example.com/callback" }
  let(:code_verifier) { "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" }
  let(:headers) { { "User-Agent" => "CompanionKit/2.3 iOS" } }

  let(:public_client) do
    StandardId::ClientApplication.create!(
      owner: account,
      name: "Companion",
      redirect_uris: redirect_uri,
      scopes: "openid profile email",
      grant_types: "authorization_code refresh_token",
      response_types: "code",
      client_type: "public",
      require_pkce: true,
      code_challenge_methods: "S256"
    )
  end

  before { StandardId.config.session.session_type_resolver = ->(**) { :device } }
  after { StandardId.config.session.session_type_resolver = nil }

  def sign_in!
    code = SecureRandom.hex(20)
    StandardId::AuthorizationCode.issue!(
      plaintext_code: code,
      client_id: public_client.client_id,
      redirect_uri: redirect_uri,
      scope: "openid profile",
      account: account,
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier)).delete("="),
      code_challenge_method: "S256"
    )
    post token_path,
      params: {
        grant_type: "authorization_code",
        client_id: public_client.client_id,
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: code_verifier
      },
      headers: headers,
      as: :json
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  def sign_out!(access_token)
    post "/api/oauth/revoke", params: { token: access_token }, headers: headers
    expect(response).to have_http_status(:ok)
  end

  def refresh!(refresh_token)
    post token_path,
      params: { grant_type: "refresh_token", client_id: public_client.client_id, refresh_token: refresh_token },
      headers: headers,
      as: :json
  end

  def session_for(refresh_token)
    jti = StandardId::JwtService.decode(refresh_token)[:jti]
    StandardId::RefreshToken.eager_load(:session).find_by_jti(jti).session
  end

  it "gives the second sign-in a fresh session that can refresh" do
    first = sign_in!
    first_session = session_for(first["refresh_token"])
    expect(first_session).to be_a(StandardId::DeviceSession)

    sign_out!(first["access_token"])
    expect(first_session.reload).to be_revoked

    second = sign_in!
    second_session = session_for(second["refresh_token"])
    expect(second_session.id).not_to eq(first_session.id)
    expect(second_session).not_to be_revoked
    expect(second_session.device_id).to eq(first_session.device_id)

    refresh!(second["refresh_token"])

    expect(response).to have_http_status(:ok), -> { "refresh refused: #{response.body}" }
    body = JSON.parse(response.body)
    expect(body["refresh_token"]).to be_present
    expect(session_for(body["refresh_token"]).id).to eq(second_session.id)

    # The revoked row is kept as history, not resurrected.
    expect(first_session.reload).to be_revoked
    expect(StandardId::DeviceSession.where(account: account).count).to eq(2)
  end

  it "still reuses the active row for repeat sign-ins without a sign-out" do
    first = sign_in!
    second = sign_in!

    expect(session_for(second["refresh_token"]).id).to eq(session_for(first["refresh_token"]).id)
    expect(StandardId::DeviceSession.where(account: account).count).to eq(1)
  end
end
