require "rails_helper"

RSpec.describe StandardId::Providers::Google do
  let(:google_client_id) { "google_client_123" }
  let(:google_client_secret) { "google_secret" }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return(google_client_id)
    allow(StandardId.config).to receive(:google_client_secret).and_return(google_client_secret)
  end

  describe "interface compliance" do
    it "inherits from Base" do
      expect(described_class).to be < StandardId::Providers::Base
    end

    it "is registered with the provider registry" do
      expect(StandardId::ProviderRegistry.get(:google)).to eq(described_class)
    end
  end

  describe ".provider_name" do
    it 'returns "google"' do
      expect(described_class.provider_name).to eq("google")
    end
  end

  describe ".default_scope" do
    it 'returns "openid email profile"' do
      expect(described_class.default_scope).to eq("openid email profile")
    end
  end

  describe ".authorization_url" do
    let(:state) { "encoded_state_value" }
    let(:redirect_uri) { "https://example.com/callback" }

    it "generates a valid Google OAuth URL" do
      url = described_class.authorization_url(
        state: state,
        redirect_uri: redirect_uri,
        prompt: "select_account"
      )

      expect(url).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
      expect(url).to include("client_id=#{google_client_id}")
      expect(url).to include("redirect_uri=#{CGI.escape(redirect_uri)}")
      expect(url).to include("response_type=code")
      expect(url).to include("scope=openid+email+profile")
      expect(url).to include("state=#{state}")
      expect(url).to include("prompt=select_account")
    end

    it "accepts custom scope" do
      url = described_class.authorization_url(
        state: state,
        redirect_uri: redirect_uri,
        scope: "email profile"
      )

      expect(url).to include("scope=email+profile")
    end

    it "omits prompt parameter when nil" do
      url = described_class.authorization_url(
        state: state,
        redirect_uri: redirect_uri,
        prompt: nil
      )

      expect(url).not_to include("prompt=")
    end
  end

  describe ".get_user_info" do
    context "with id_token" do
      let(:id_token) { "mobile_id_token" }
      let(:user_info) { { "email" => "user@example.com", "name" => "Test User" } }

      it "verifies id_token directly" do
        expect(described_class).to receive(:verify_id_token)
          .with(id_token: id_token)
          .and_return(user_info)

        result = described_class.get_user_info(
          id_token: id_token
        )

        expect(result[:user_info]).to eq(user_info)
        expect(result[:tokens]).to eq({ id_token: id_token }.with_indifferent_access)
      end
    end

    context "with access_token (implicit/legacy flow)" do
      let(:access_token) { "mobile_access_token" }
      let(:user_info) { { "email" => "user@example.com", "name" => "Test User" } }

      it "fetches user info directly" do
        expect(described_class).to receive(:fetch_user_info)
          .with(access_token: access_token)
          .and_return(user_info)

        result = described_class.get_user_info(
          access_token: access_token
        )

        expect(result[:user_info]).to eq(user_info)
        expect(result[:tokens]).to eq({ access_token: access_token }.with_indifferent_access)
      end
    end

    context "with code (web flow)" do
      let(:code) { "authorization_code_123" }
      let(:redirect_uri) { "https://example.com/callback" }
      let(:user_info) { { "email" => "user@example.com", "name" => "Test User" } }

      it "exchanges code for user info" do
        expect(described_class).to receive(:exchange_code_for_user_info)
          .with(code: code, redirect_uri: redirect_uri)
          .and_return({ user_info: user_info, tokens: { access_token: "exchanged" } })

        result = described_class.get_user_info(
          code: code,
          redirect_uri: redirect_uri
        )

        expect(result[:user_info]).to eq(user_info)
        expect(result[:tokens]).to include(:access_token)
      end
    end

    context "with none of code, id_token, or access_token" do
      it "raises an error" do
        expect {
          described_class.get_user_info
        }.to raise_error(StandardId::InvalidRequestError, "Either code, id_token, or access_token must be provided")
      end
    end
  end

  describe ".exchange_code_for_user_info" do
    let(:code) { "authorization_code_123" }
    let(:redirect_uri) { "https://example.com/callback" }
    let(:access_token) { "exchanged_access_token" }
    let(:user_info) { { "email" => "user@example.com", "name" => "Test User", "sub" => "123456" } }

    it "exchanges code for access token and fetches user info" do
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .with(body: {
          client_id: google_client_id,
          client_secret: google_client_secret,
          code: code,
          grant_type: "authorization_code",
          redirect_uri: redirect_uri
        })
        .to_return(status: 200, body: { access_token: access_token, token_type: "Bearer" }.to_json)

      stub_request(:post, "https://www.googleapis.com/oauth2/v3/tokeninfo")
        .with(body: { access_token: access_token })
        .to_return(status: 200, body: { aud: google_client_id, sub: "123456" }.to_json)

      stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
        .with(headers: { "Authorization" => "Bearer #{access_token}" })
        .to_return(status: 200, body: user_info.to_json)

      result = described_class.exchange_code_for_user_info(
        code: code,
        redirect_uri: redirect_uri
      )

      expect(result[:user_info]).to eq(user_info)
      expect(result[:tokens]).to include(
        access_token: access_token,
      )
    end

    it "raises error when code is blank" do
      expect {
        described_class.exchange_code_for_user_info(
          code: "",
          redirect_uri: redirect_uri
        )
      }.to raise_error(StandardId::InvalidRequestError, "Missing authorization code")
    end

    it "raises error when token exchange fails" do
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 400, body: { error: "invalid_grant" }.to_json)

      expect {
        described_class.exchange_code_for_user_info(
          code: code,
          redirect_uri: redirect_uri
        )
      }.to raise_error(StandardId::InvalidRequestError, "Failed to exchange Google authorization code")
    end

    it "raises error when access_token is missing from response" do
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 200, body: {}.to_json)

      expect {
        described_class.exchange_code_for_user_info(
          code: code,
          redirect_uri: redirect_uri
        )
      }.to raise_error(StandardId::InvalidRequestError, "Google response missing access token")
    end
  end

  describe ".verify_id_token" do
    let(:id_token) { "valid_id_token" }
    let(:token_info) do
      {
        iss: "accounts.google.com",
        aud: google_client_id,
        sub: "123456789",
        email: "user@example.com",
        email_verified: "true",
        name: "Test User",
        given_name: "Test",
        family_name: "User",
        picture: "https://lh3.googleusercontent.com/a/default-user",
        locale: "en"
      }
    end

    it "verifies id_token and returns user info" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { id_token: id_token })
        .to_return(status: 200, body: token_info.to_json)

      result = described_class.verify_id_token(
        id_token: id_token
      )

      expect(result["sub"]).to eq("123456789")
      expect(result["email"]).to eq("user@example.com")
      expect(result["name"]).to eq("Test User")
      expect(result["given_name"]).to eq("Test")
      expect(result["family_name"]).to eq("User")
    end

    it "raises error when id_token is blank" do
      expect {
        described_class.verify_id_token(
          id_token: ""
        )
      }.to raise_error(StandardId::InvalidRequestError, "Missing id_token")
    end

    it "raises error when id_token verification fails" do
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 400, body: { error: "invalid_token" }.to_json)

      expect {
        described_class.verify_id_token(
          id_token: id_token
        )
      }.to raise_error(StandardId::InvalidRequestError, "Invalid or expired id_token")
    end

    it "raises error when audience mismatches" do
      mismatched_token_info = token_info.merge("aud" => "wrong_client_id")
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: mismatched_token_info.to_json)

      expect {
        described_class.verify_id_token(
          id_token: id_token
        )
      }.to raise_error(StandardId::InvalidRequestError, /ID token audience mismatch/)
    end

    it "raises error when issuer is invalid" do
      invalid_issuer_token_info = token_info.merge("iss" => "evil.com")
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .to_return(status: 200, body: invalid_issuer_token_info.to_json)

      expect {
        described_class.verify_id_token(
          id_token: id_token
        )
      }.to raise_error(StandardId::InvalidRequestError, /ID token issuer invalid/)
    end

    it "works with https:// prefixed issuer" do
      https_issuer_token_info = token_info.merge("iss" => "https://accounts.google.com")
      stub_request(:post, "https://oauth2.googleapis.com/tokeninfo")
        .with(body: { id_token: id_token })
        .to_return(status: 200, body: https_issuer_token_info.to_json)

      result = described_class.verify_id_token(
        id_token: id_token
      )

      expect(result["email"]).to eq("user@example.com")
    end
  end

  describe ".fetch_user_info" do
    let(:access_token) { "valid_access_token" }
    let(:user_info) { { "email" => "user@example.com", "name" => "Test User", "sub" => "123456" } }

    it "verifies token and fetches user info" do
      stub_request(:post, "https://www.googleapis.com/oauth2/v3/tokeninfo")
        .with(body: { access_token: access_token })
        .to_return(status: 200, body: { aud: google_client_id, sub: "123456" }.to_json)

      stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
        .with(headers: { "Authorization" => "Bearer #{access_token}" })
        .to_return(status: 200, body: user_info.to_json)

      result = described_class.fetch_user_info(
        access_token: access_token
      )

      expect(result).to eq(user_info)
    end

    it "raises error when access_token is blank" do
      expect {
        described_class.fetch_user_info(
          access_token: ""
        )
      }.to raise_error(StandardId::InvalidRequestError, "Missing access token")
    end

    it "raises error when user info fetch fails" do
      stub_request(:post, "https://www.googleapis.com/oauth2/v3/tokeninfo")
        .to_return(status: 200, body: { aud: google_client_id }.to_json)

      stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
        .to_return(status: 401, body: { error: "invalid_token" }.to_json)

      expect {
        described_class.fetch_user_info(
          access_token: access_token
        )
      }.to raise_error(StandardId::InvalidRequestError, "Failed to fetch Google user info")
    end
  end

  describe ".verify_token" do
    let(:access_token) { "valid_access_token" }
    let(:expected_client_id) { google_client_id }
    let(:token_info) { { "aud" => expected_client_id, "sub" => "123456", "exp" => (Time.now + 3600).to_i } }

    it "verifies token with matching client_id" do
      stub_request(:post, "https://www.googleapis.com/oauth2/v3/tokeninfo")
        .with(body: { access_token: access_token })
        .to_return(status: 200, body: token_info.to_json)

      result = described_class.send(:verify_token, access_token)

      expect(result).to eq(token_info)
    end

    it "raises error when token verification fails" do
      stub_request(:post, "https://www.googleapis.com/oauth2/v3/tokeninfo")
        .to_return(status: 400, body: { error: "invalid_token" }.to_json)

      expect {
        described_class.send(:verify_token, access_token)
      }.to raise_error(StandardId::InvalidRequestError, "Invalid or expired access token")
    end

    it "raises error when audience mismatches" do
      stub_request(:post, "https://www.googleapis.com/oauth2/v3/tokeninfo")
        .to_return(status: 200, body: { aud: "wrong_client_id", sub: "123456" }.to_json)

      expect {
        described_class.send(:verify_token, access_token)
      }.to raise_error(StandardId::InvalidRequestError, /Access token audience mismatch/)
    end
  end
end
