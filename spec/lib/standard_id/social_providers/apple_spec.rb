require "rails_helper"

RSpec.describe StandardId::SocialProviders::Apple do
  let(:apple_client_id) { "com.example.app" }
  let(:apple_team_id) { "TEAM123456" }
  let(:apple_key_id) { "KEY123456" }
  let(:apple_private_key) { OpenSSL::PKey::EC.generate("prime256v1").to_pem }
  let(:test_rsa_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:test_kid) { "TEST_KID_123" }

  before do
    StandardId.config.apple_client_id = apple_client_id
    StandardId.config.apple_team_id = apple_team_id
    StandardId.config.apple_key_id = apple_key_id
    StandardId.config.apple_private_key = apple_private_key
  end

  after do
    StandardId.config.apple_client_id = nil
    StandardId.config.apple_team_id = nil
    StandardId.config.apple_key_id = nil
    StandardId.config.apple_private_key = nil
  end

  describe ".authorization_url" do
    let(:redirect_uri) { "https://example.com/auth/apple/callback" }
    let(:state) { "random_state_string" }

    context "when credentials are configured" do
      it "generates the correct authorization URL" do
        url = described_class.authorization_url(
          state: state,
          redirect_uri: redirect_uri
        )

        uri = URI.parse(url)
        params = URI.decode_www_form(uri.query).to_h

        expect(uri.scheme).to eq("https")
        expect(uri.host).to eq("appleid.apple.com")
        expect(uri.path).to eq("/auth/authorize")
        expect(params["client_id"]).to eq(apple_client_id)
        expect(params["redirect_uri"]).to eq(redirect_uri)
        expect(params["response_type"]).to eq("code")
        expect(params["state"]).to eq(state)
        expect(params["scope"]).to eq("name email")
        expect(params["response_mode"]).to eq("form_post")
      end

      it "allows custom scope" do
        url = described_class.authorization_url(
          state: state,
          redirect_uri: redirect_uri,
          scope: "email"
        )

        uri = URI.parse(url)
        params = URI.decode_www_form(uri.query).to_h

        expect(params["scope"]).to eq("email")
      end

      it "allows custom response_mode" do
        url = described_class.authorization_url(
          state: state,
          redirect_uri: redirect_uri,
          response_mode: "query"
        )

        uri = URI.parse(url)
        params = URI.decode_www_form(uri.query).to_h

        expect(params["response_mode"]).to eq("query")
      end
    end

    context "when client_id is not configured" do
      before { StandardId.config.apple_client_id = nil }

      it "raises an error" do
        expect {
          described_class.authorization_url(state: state, redirect_uri: redirect_uri)
        }.to raise_error(StandardId::InvalidRequestError, /Apple OAuth is not configured/)
      end
    end
  end

  describe ".get_user_info" do
    context "with id_token" do
      let(:user_sub) { "001234.abcd1234abcd1234abcd1234abcd1234.1234" }
      let(:user_email) { "user@example.com" }

      it "verifies and returns user info from id_token" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email)
        stub_jwks_request

        result = described_class.get_user_info(id_token: id_token)

        expect(result["sub"]).to eq(user_sub)
        expect(result["email"]).to eq(user_email)
      end

      it "raises error when id_token is blank" do
        expect {
          described_class.get_user_info(id_token: "")
        }.to raise_error(StandardId::InvalidRequestError, /Either code or id_token must be provided/)
      end
    end

    context "with authorization code" do
      let(:code) { "test_auth_code" }
      let(:redirect_uri) { "https://example.com/auth/apple/callback" }
      let(:user_sub) { "001234.abcd1234abcd1234abcd1234abcd1234.1234" }
      let(:user_email) { "user@example.com" }

      it "exchanges code for user info" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email)
        stub_token_exchange_request(code: code, id_token: id_token)
        stub_jwks_request

        result = described_class.get_user_info(code: code, redirect_uri: redirect_uri)

        expect(result["sub"]).to eq(user_sub)
        expect(result["email"]).to eq(user_email)
      end

      it "raises error when code is blank" do
        expect {
          described_class.get_user_info(code: "", redirect_uri: redirect_uri)
        }.to raise_error(StandardId::InvalidRequestError, /Either code or id_token must be provided/)
      end
    end

    context "when neither code nor id_token is provided" do
      it "raises an error" do
        expect {
          described_class.get_user_info
        }.to raise_error(StandardId::InvalidRequestError, /Either code or id_token must be provided/)
      end
    end
  end

  describe ".exchange_code_for_user_info" do
    let(:code) { "test_authorization_code" }
    let(:redirect_uri) { "https://example.com/auth/apple/callback" }
    let(:user_sub) { "001234.abcd1234abcd1234abcd1234abcd1234.1234" }
    let(:user_email) { "user@privaterelay.appleid.com" }

    context "with valid credentials" do
      it "exchanges authorization code for user info" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email, is_private_email: true)
        stub_token_exchange_request(code: code, id_token: id_token)
        stub_jwks_request

        result = described_class.exchange_code_for_user_info(
          code: code,
          redirect_uri: redirect_uri
        )

        expect(result["sub"]).to eq(user_sub)
        expect(result["email"]).to eq(user_email)
        expect(result["is_private_email"]).to eq("true")
      end

      it "generates a valid client_secret JWT" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email, is_private_email: true)
        stub_token_exchange_request(code: code, id_token: id_token)
        stub_jwks_request

        described_class.exchange_code_for_user_info(
          code: code,
          redirect_uri: redirect_uri
        )

        # Verify the client_secret was sent correctly
        expect(WebMock).to have_requested(:post, "https://appleid.apple.com/auth/token")
          .with { |req|
            body = URI.decode_www_form(req.body).to_h
            client_secret = body["client_secret"]

            # Decode the JWT to verify its structure
            decoded = JWT.decode(client_secret, nil, false)[0]

            expect(decoded["iss"]).to eq(apple_team_id)
            expect(decoded["aud"]).to eq("https://appleid.apple.com")
            expect(decoded["sub"]).to eq(apple_client_id)
            expect(decoded["iat"]).to be_a(Integer)
            expect(decoded["exp"]).to be_a(Integer)
            expect(decoded["exp"] - decoded["iat"]).to eq(3600)

            true
          }
      end
    end

    context "with mobile client identifier" do
      let(:mobile_client_id) { "com.example.mobileapp" }

      before do
        StandardId.config.apple_mobile_client_id = mobile_client_id
      end

      after do
        StandardId.config.apple_mobile_client_id = nil
      end

      it "uses provided client_id for exchange" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email, aud: mobile_client_id)
        stub_token_exchange_request(code: code, id_token: id_token, client_id: mobile_client_id)
        stub_jwks_request

        result = described_class.exchange_code_for_user_info(
          code: code,
          redirect_uri: redirect_uri,
          client_id: mobile_client_id
        )

        expect(result["sub"]).to eq(user_sub)
      end
    end

    context "when token exchange fails" do
      it "raises an error with the failure reason" do
        stub_request(:post, "https://appleid.apple.com/auth/token")
          .to_return(
            status: 400,
            body: { error: "invalid_grant", error_description: "code is invalid" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect {
          described_class.exchange_code_for_user_info(
            code: code,
            redirect_uri: redirect_uri
          )
        }.to raise_error(StandardId::InvalidRequestError, /Failed to exchange Apple authorization code/)
      end
    end

    context "when id_token is missing from response" do
      it "raises an error" do
        stub_request(:post, "https://appleid.apple.com/auth/token")
          .to_return(
            status: 200,
            body: { access_token: "token123" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect {
          described_class.exchange_code_for_user_info(
            code: code,
            redirect_uri: redirect_uri
          )
        }.to raise_error(StandardId::InvalidRequestError, /Apple response missing id_token/)
      end
    end

    context "when credentials are incomplete" do
      before { StandardId.config.apple_private_key = nil }

      it "raises an error" do
        expect {
          described_class.exchange_code_for_user_info(
            code: code,
            redirect_uri: redirect_uri
          )
        }.to raise_error(StandardId::InvalidRequestError, /Apple OAuth credentials are incomplete/)
      end
    end
  end

  describe ".verify_id_token" do
    let(:user_sub) { "001234.abcd1234abcd1234abcd1234abcd1234.1234" }
    let(:user_email) { "user@example.com" }

    context "with valid id_token" do
      it "verifies signature and returns user info" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email, email_verified: true)
        stub_jwks_request

        result = described_class.verify_id_token(id_token: id_token)

        expect(result["sub"]).to eq(user_sub)
        expect(result["email"]).to eq(user_email)
        expect(result["email_verified"]).to eq("true")
      end
    end

    context "with expired id_token" do
      it "raises an error" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email, exp: Time.now.to_i - 3600)
        stub_jwks_request

        expect {
          described_class.verify_id_token(id_token: id_token)
        }.to raise_error(StandardId::InvalidRequestError, /Invalid Apple ID token/)
      end
    end

    context "with wrong audience" do
      it "raises an error" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email, aud: "wrong.client.id")
        stub_jwks_request

        expect {
          described_class.verify_id_token(id_token: id_token)
        }.to raise_error(StandardId::InvalidRequestError, /Invalid Apple ID token audience/)
      end
    end

    context "with mobile client ID" do
      let(:mobile_client_id) { "com.example.mobileapp" }

      before do
        StandardId.config.apple_mobile_client_id = mobile_client_id
      end

      after do
        StandardId.config.apple_mobile_client_id = nil
      end

      it "verifies id_token with mobile client_id successfully" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email, aud: mobile_client_id)
        stub_jwks_request

        result = described_class.verify_id_token(id_token: id_token, client_id: mobile_client_id)

        expect(result["sub"]).to eq(user_sub)
        expect(result["email"]).to eq(user_email)
      end
    end

    context "with invalid signature" do
      it "raises an error" do
        wrong_key = OpenSSL::PKey::RSA.new(2048)
        wrong_kid = "WRONGKID"
        payload = {
          iss: "https://appleid.apple.com",
          aud: apple_client_id,
          sub: user_sub,
          email: user_email,
          iat: Time.now.to_i,
          exp: Time.now.to_i + 3600
        }
        id_token = JWT.encode(payload, wrong_key, "RS256", kid: wrong_kid)

        # Stub JWKS to return keys that don't include the wrong KID
        stub_request(:get, "https://appleid.apple.com/auth/keys")
          .to_return(
            status: 200,
            body: { keys: [] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect {
          described_class.verify_id_token(id_token: id_token)
        }.to raise_error(StandardId::InvalidRequestError, /JWK with kid .* not found/)
      end
    end

    context "when JWKS fetch fails" do
      it "raises an error" do
        id_token = generate_test_id_token(sub: user_sub, email: user_email)
        stub_request(:get, "https://appleid.apple.com/auth/keys")
          .to_return(status: 500)

        expect {
          described_class.verify_id_token(id_token: id_token)
        }.to raise_error(StandardId::InvalidRequestError, /Failed to fetch Apple JWKS/)
      end
    end
  end

  def generate_test_id_token(sub:, email:, email_verified: nil, is_private_email: nil, aud: nil, exp: nil)
    payload = {
      iss: "https://appleid.apple.com",
      aud: aud || apple_client_id,
      sub: sub,
      email: email,
      iat: Time.now.to_i,
      exp: exp || (Time.now.to_i + 3600)
    }

    payload[:email_verified] = email_verified.to_s if email_verified
    payload[:is_private_email] = is_private_email.to_s if is_private_email

    JWT.encode(payload, test_rsa_key, "RS256", kid: test_kid)
  end

  def stub_jwks_request
    # Create JWK from the test RSA key
    jwk = JWT::JWK.new(test_rsa_key)
    jwk_hash = jwk.export.merge(
      kid: test_kid,
      alg: "RS256",
      use: "sig"
    )

    stub_request(:get, "https://appleid.apple.com/auth/keys")
      .to_return(
        status: 200,
        body: { keys: [jwk_hash] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_token_exchange_request(code:, id_token:, client_id: apple_client_id)
    stub_request(:post, "https://appleid.apple.com/auth/token")
      .with { |req|
        body = URI.decode_www_form(req.body).to_h
        body["code"] == code &&
          body["grant_type"] == "authorization_code" &&
          body["client_id"] == client_id
      }
      .to_return(
        status: 200,
        body: {
          access_token: "test_access_token",
          token_type: "Bearer",
          expires_in: 3600,
          refresh_token: "test_refresh_token",
          id_token: id_token
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
