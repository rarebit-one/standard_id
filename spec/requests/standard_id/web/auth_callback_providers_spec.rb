require "rails_helper"

RSpec.describe "StandardId Web Social Auth Callbacks", type: :request do
  def state_for(redirect_uri)
    Base64.urlsafe_encode64({ redirect_uri: redirect_uri }.to_json)
  end

  describe "GET /auth/callback/google" do
    it "signs in and redirects to decoded redirect_uri with notice" do
      http_get "/auth/callback/google", params: { state: state_for("/dashboard"), email: "user@example.com", name: "Test User", sub: "prov_123" }

      expect(response).to redirect_to("/dashboard")
      follow_redirect! if response.redirect?
      # After sign-in, a browser session should exist for created account
      account = Account.find_by(email: "user@example.com")
      expect(account).to be_present
      expect(account.sessions.active).to exist
    end

    it "defaults to root path when state missing or invalid" do
      http_get "/auth/callback/google", params: { email: "user@example.com" }
      expect(response).to redirect_to("/")

      http_get "/auth/callback/google", params: { state: "not_base64", email: "user@example.com" }
      expect(response).to redirect_to("/")
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
    it "signs in and redirects to decoded redirect_uri with notice" do
      http_post "/auth/callback/apple", params: { state: state_for("/dashboard"), email: "user@privaterelay.appleid.com", name: "Apple User", sub: "apple_123" }

      expect(response).to redirect_to("/dashboard")
    end

    it "defaults to root path when state missing or invalid" do
      http_post "/auth/callback/apple", params: { email: "user@privaterelay.appleid.com" }
      expect(response).to redirect_to("/")

      http_post "/auth/callback/apple", params: { state: "not_base64", email: "user@privaterelay.appleid.com" }
      expect(response).to redirect_to("/")
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
