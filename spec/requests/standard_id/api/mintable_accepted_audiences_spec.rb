require "rails_helper"

# oauth.mintable_audiences / oauth.accepted_audiences split what an app issues
# from what its API accepts (rarebit-one/rarebit-ops#494). The IdP shape: it
# mints per-service tokens (aud=harness) but its own API accepts only its own
# audience.
RSpec.describe "Mintable vs accepted audiences", type: :request do
  let(:token_path) { api_standard_id_api.oauth_token_path }
  let(:account) { Account.create!(name: "Audience User", email: "split-aud-#{SecureRandom.hex(4)}@example.com") }
  let(:oauth) { StandardId.config.oauth }

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def mint(audience)
    StandardId::TokenMinter.mint(account: account, audience: audience, grant_type: "test.mint").access_token
  end

  def jwt_aud(token)
    JWT.decode(token, nil, false).first["aud"]
  end

  let(:client_account) { Account.create!(name: "Client Owner", email: "split-client-#{SecureRandom.hex(4)}@example.com") }
  let(:client_secret_value) { "split_secret_#{SecureRandom.hex(8)}" }
  let(:client_app) do
    StandardId::ClientApplication.create!(
      owner: client_account,
      name: "Split Audience Client",
      redirect_uris: "https://example.com/callback",
      scopes: "read",
      grant_types: "client_credentials"
    )
  end

  before do
    credential = client_app.create_client_secret!(name: "Split Secret", client_secret: client_secret_value)
    identifier = StandardId::EmailIdentifier.create!(
      account: client_account, value: "split-cred-#{SecureRandom.hex(4)}@example.com", verified_at: Time.current
    )
    StandardId::Credential.create!(credentialable: credential, identifier: identifier)
  end

  def client_credentials(audience)
    post token_path,
      params: { grant_type: "client_credentials", client_id: client_app.client_id, client_secret: client_secret_value, audience: audience },
      as: :json
  end

  describe "defaults (only allowed_audiences set)" do
    before { allow(oauth).to receive(:allowed_audiences).and_return(%w[web harness]) }

    it "mints and accepts the same list, as before the split" do
      client_credentials("harness")
      expect(response).to have_http_status(:ok)

      get "/api/sessions", headers: bearer(mint("harness"))
      expect(response).to have_http_status(:ok)
    end

    it "still refuses to mint an audience outside allowed_audiences" do
      client_credentials("inference")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_request")
    end
  end

  describe "identity provider: mints service audiences it does not accept" do
    before do
      allow(oauth).to receive(:allowed_audiences).and_return([])
      allow(oauth).to receive(:mintable_audiences).and_return(%w[sidekick harness inference])
      allow(oauth).to receive(:accepted_audiences).and_return(%w[sidekick])
    end

    it "mints a harness token through TokenMinter" do
      expect(jwt_aud(mint("harness"))).to eq("harness")
    end

    it "rejects that harness token on its own API with 401 invalid_token" do
      get "/api/sessions", headers: bearer(mint("harness"))

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("invalid_token")
    end

    it "accepts a token for its own audience on its API" do
      get "/api/sessions", headers: bearer(mint("sidekick"))

      expect(response).to have_http_status(:ok)
    end

    it "issues client_credentials tokens for a mintable service audience" do
      client_credentials("inference")

      expect(response).to have_http_status(:ok)
      expect(jwt_aud(response.parsed_body["access_token"])).to eq("inference")
    end

    it "refuses client_credentials for an audience outside mintable_audiences" do
      client_credentials("billing")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_request")
    end

    it "refuses TokenMinter for an audience outside mintable_audiences" do
      expect { mint("billing") }.to raise_error(StandardId::InvalidRequestError, /Invalid audience: billing/)
    end

    describe "authorization_code exchange" do
      let(:redirect_uri) { "https://app.example.com/callback" }
      let(:code_verifier) { "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" }
      let(:public_client) do
        StandardId::ClientApplication.create!(
          owner: account,
          name: "Split Public Client",
          redirect_uris: redirect_uri,
          scopes: "openid profile",
          grant_types: "authorization_code refresh_token",
          response_types: "code",
          client_type: "public",
          require_pkce: true,
          code_challenge_methods: "S256"
        )
      end

      def exchange(audience)
        code = SecureRandom.hex(20)
        StandardId::AuthorizationCode.issue!(
          plaintext_code: code,
          client_id: public_client.client_id,
          redirect_uri: redirect_uri,
          scope: "openid profile",
          audience: audience,
          account: account,
          code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier)).delete("="),
          code_challenge_method: "S256"
        )
        post token_path,
          params: {
            grant_type: "authorization_code", client_id: public_client.client_id,
            code: code, redirect_uri: redirect_uri, code_verifier: code_verifier
          },
          as: :json
      end

      it "issues a token for a mintable audience the API does not accept" do
        exchange("harness")

        expect(response).to have_http_status(:ok)
        expect(jwt_aud(response.parsed_body["access_token"])).to eq("harness")
      end

      it "refuses a code bound to an audience outside mintable_audiences" do
        exchange("billing")

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("invalid_request")
      end
    end
  end
end
