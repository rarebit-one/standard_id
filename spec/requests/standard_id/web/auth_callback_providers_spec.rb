require "rails_helper"

RSpec.describe "StandardId Web Social Auth Callbacks", type: :request do
  def state_for(redirect_uri)
    Base64.urlsafe_encode64({ redirect_uri: redirect_uri }.to_json)
  end

  describe "GET /auth/callback/google" do
    let(:state) { state_for("/dashboard") }

    before do
      allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
      allow(StandardId.config).to receive(:google_client_secret).and_return("google-secret")
      allow(StandardId::SocialProviders::Google).to receive(:get_user_info).and_return(
        { "email" => "user@example.com", "name" => "Test User", "sub" => "prov_123" }
      )
    end

    it "signs in and redirects to decoded redirect_uri with notice" do
      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(StandardId::SocialProviders::Google).to have_received(:get_user_info).with(
        hash_including(code: "auth_code_123", redirect_uri: "http://www.example.com/auth/callback/google")
      )
      expect(response).to redirect_to("/dashboard")
      follow_redirect! if response.redirect?
      account = Account.find_by(email: "user@example.com")
      expect(account).to be_present
      expect(account.sessions.active).to exist
    end

    it "redirects to login when state missing" do
      http_get "/auth/callback/google", params: { code: "auth_code_123" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Missing state parameter")
    end

    it "redirects to login when state invalid" do
      http_get "/auth/callback/google", params: { state: "not_base64", code: "auth_code_123" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid state parameter")
    end

    it "redirects to login with error when provider passes error param (access_denied)" do
      http_get "/auth/callback/google", params: { error: "access_denied" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication was cancelled")
    end

    it "redirects to login with error when provider passes error param (invalid_request)" do
      http_get "/auth/callback/google", params: { error: "invalid_request" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Invalid authentication request")
    end

    it "redirects to login with generic error when provider passes unknown error" do
      http_get "/auth/callback/google", params: { error: "some_error" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication failed")
    end
  end

  describe "POST /auth/callback/apple" do
    let(:apple_state) { state_for("/dashboard") }

    before do
      allow(StandardId::SocialProviders::Apple).to receive(:get_user_info).and_return(
        { "email" => "user@privaterelay.appleid.com", "name" => "Apple User", "sub" => "apple_123" }
      )
    end

    it "signs in and redirects to decoded redirect_uri with notice" do
      http_post "/auth/callback/apple", params: { state: apple_state, code: "apple_code_123" }

      expect(StandardId::SocialProviders::Apple).to have_received(:get_user_info).with(
        hash_including(code: "apple_code_123", redirect_uri: "http://www.example.com/auth/callback/apple")
      )
      expect(response).to redirect_to("/dashboard")
    end

    it "redirects to login when state missing or invalid" do
      http_post "/auth/callback/apple", params: { email: "user@privaterelay.appleid.com" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Missing state parameter")

      http_post "/auth/callback/apple", params: { state: "not_base64", email: "user@privaterelay.appleid.com" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid state parameter")
    end

    it "redirects to login with error when provider passes error param (access_denied)" do
      http_post "/auth/callback/apple", params: { error: "access_denied" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication was cancelled")
    end

    it "redirects to login with error when provider passes error param (invalid_request)" do
      http_post "/auth/callback/apple", params: { error: "invalid_request" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Invalid authentication request")
    end

    it "redirects to login with generic error when provider passes unknown error" do
      http_post "/auth/callback/apple", params: { error: "some_error" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication failed")
    end
  end
end
