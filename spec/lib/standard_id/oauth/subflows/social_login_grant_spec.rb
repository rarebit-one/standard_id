require "rails_helper"

RSpec.describe StandardId::Oauth::Subflows::SocialLoginGrant do
  let(:params) do
    {
      client_id: "client_123",
      redirect_uri: "https://app.example.com/callback",
      scope: "openid profile",
      audience: "api://default",
      state: "random_state",
      code_challenge: "challenge123",
      code_challenge_method: "S256",
      connection: "google",
      base_url: "https://auth.example.com"
    }
  end

  subject { described_class.new(**params) }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
    allow(StandardId.config).to receive(:google_client_secret).and_return("google_secret")
    allow(StandardId.config).to receive(:apple_client_id).and_return("apple_client_456")
  end

  describe "#call" do
    context "with Google OAuth2" do
      it "returns redirect to Google OAuth URL" do
        result = subject.call

        expect(result[:status]).to eq(:found)
        expect(result[:redirect_to]).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
        expect(result[:redirect_to]).to include("client_id=google_client_123")
        expect(result[:redirect_to]).to include("redirect_uri=https%3A%2F%2Fauth.example.com%2Fapi%2Foauth%2Fcallback%2Fgoogle")
        expect(result[:redirect_to]).to include("response_type=code")
        expect(result[:redirect_to]).to include("scope=openid+email+profile")
        expect(result[:redirect_to]).to include("state=")
      end

      context "with Google connection" do
        let(:params) { super().merge(connection: "google") }

        it "uses googlee client id" do
          result = subject.call

          expect(result[:redirect_to]).to include("client_id=google_client_123")
        end
      end
    end

    context "with Apple Sign In" do
      let(:params) { super().merge(connection: "apple") }

      it "returns redirect to Apple OAuth URL" do
        result = subject.call

        expect(result[:status]).to eq(:found)
        expect(result[:redirect_to]).to start_with("https://appleid.apple.com/auth/authorize?")
        expect(result[:redirect_to]).to include("client_id=apple_client_456")
        expect(result[:redirect_to]).to include("redirect_uri=https%3A%2F%2Fauth.example.com%2Fapi%2Foauth%2Fcallback%2Fapple")
        expect(result[:redirect_to]).to include("response_type=code")
        expect(result[:redirect_to]).to include("scope=name+email")
        expect(result[:redirect_to]).to include("response_mode=form_post")
        expect(result[:redirect_to]).to include("state=")
      end
    end

    context "with unsupported connection" do
      let(:params) { super().merge(connection: "facebook") }

      it "raises InvalidRequestError" do
        expect { subject.call }.to raise_error(
          StandardId::InvalidRequestError,
          "Unsupported connection: facebook"
        )
      end
    end
  end

  describe "state encoding" do
    it "encodes original OAuth parameters in state" do
      result = subject.call
      state_param = URI.decode_www_form(URI.parse(result[:redirect_to]).query).find { |k, v| k == "state" }&.last

      decoded_state = JSON.parse(Base64.urlsafe_decode64(state_param))

      expect(decoded_state).to include(
        "client_id" => "client_123",
        "redirect_uri" => "https://app.example.com/callback",
        "scope" => "openid profile",
        "audience" => "api://default",
        "state" => "random_state",
        "code_challenge" => "challenge123",
        "code_challenge_method" => "S256"
      )
    end

    it "omits nil values from encoded state" do
      params.delete(:state)
      params.delete(:code_challenge)
      subject = described_class.new(**params)

      result = subject.call
      state_param = URI.decode_www_form(URI.parse(result[:redirect_to]).query).find { |k, v| k == "state" }&.last

      decoded_state = JSON.parse(Base64.urlsafe_decode64(state_param))

      expect(decoded_state).not_to have_key("state")
      expect(decoded_state).not_to have_key("code_challenge")
      expect(decoded_state).not_to have_key("code_challenge_method")
    end
  end
end
