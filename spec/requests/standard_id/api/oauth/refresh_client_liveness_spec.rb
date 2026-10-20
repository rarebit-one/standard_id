require "rails_helper"

# Deleting or deactivating a ClientApplication ends the refresh tokens it was
# issued: the refresh_token grant binds each token to the application the
# authorization_code grant resolved (migration 20261020000000) and refuses the
# rotation with the same invalid_grant every other dead token gets. Deleting a
# client is the only revocation RFC 7592 gives a client manager, and a public
# client never sends a secret, so before this nothing on the refresh path
# looked the client up at all.
RSpec.describe "Refresh after the client application is deactivated or deleted", type: :request do
  let(:token_path) { "/api/oauth/token" }
  let(:redirect_uri) { "https://client.example.com/callback" }
  let(:account) { Account.create!(name: "Owner", email: "liveness-#{SecureRandom.hex(4)}@example.com") }
  let(:client_secret) { "s3cret-#{SecureRandom.hex(8)}" }
  let(:client) do
    StandardId::ClientApplication.create!(
      owner: account, name: "Confidential Client", redirect_uris: redirect_uri,
      client_type: "confidential", require_pkce: false, scopes: "openid profile"
    )
  end
  let!(:credential) { client.create_client_secret!(name: "secret", client_secret: client_secret) }

  def json = JSON.parse(response.body)

  def exchange_code!
    code = SecureRandom.hex(20)
    StandardId::AuthorizationCode.create!(
      account: account,
      code_hash: StandardId::AuthorizationCode.hash_for(code),
      client_id: client.client_id,
      redirect_uri: redirect_uri,
      scope: "openid profile",
      issued_at: Time.current,
      expires_at: 10.minutes.from_now
    )
    post token_path, params: {
      grant_type: "authorization_code", code: code, client_id: client.client_id,
      client_secret: client_secret, redirect_uri: redirect_uri
    }, as: :json
    expect(response).to have_http_status(:ok)
    json
  end

  def refresh!(refresh_token)
    post token_path, params: {
      grant_type: "refresh_token", refresh_token: refresh_token,
      client_id: client.client_id, client_secret: client_secret
    }, as: :json
  end

  def record_for(refresh_token)
    StandardId::RefreshToken.find_by_jti(StandardId::JwtService.decode(refresh_token)[:jti])
  end

  it "binds the minted refresh token to the application and keeps the binding across rotation" do
    tokens = exchange_code!
    expect(record_for(tokens["refresh_token"]).client_application_id).to eq(client.id)

    refresh!(tokens["refresh_token"])

    expect(response).to have_http_status(:ok)
    expect(record_for(json["refresh_token"]).client_application_id).to eq(client.id)
  end

  it "refuses a refresh once the application is deleted" do
    tokens = exchange_code!
    refresh!(tokens["refresh_token"])
    latest = json["refresh_token"]

    client.strict_loading!(false)
    client.destroy!
    # The secret went with the application; a deleted public client would send
    # none anyway. The refusal must come from the binding, not from the secret.
    post token_path, params: { grant_type: "refresh_token", refresh_token: latest, client_id: client.client_id }, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(json).to eq("error" => "invalid_grant", "error_description" => "Refresh token is no longer valid")
  end

  it "refuses a refresh while the application is deactivated and honours it again once reactivated" do
    tokens = exchange_code!

    client.deactivate!
    refresh!(tokens["refresh_token"])
    expect(response).to have_http_status(:bad_request)
    expect(json["error"]).to eq("invalid_grant")

    client.activate!
    refresh!(tokens["refresh_token"])
    expect(response).to have_http_status(:ok)
  end
end
