require "rails_helper"

RSpec.describe StandardId::Web::Auth::Callback::ProvidersController, type: :controller do
  routes { StandardId::WebEngine.routes }

  let(:browser_session) { double("BrowserSession") }
  let(:session_manager_double) { double("StandardId::Web::SessionManager", sign_in_account: true, current_session: browser_session) }
  let(:account) { Account.create!(email: "user@example.com", name: "Web User") }
  let(:user_info) do
    {
      email: "user@example.com",
      name: "Test User",
      provider: provider,
      provider_id: "prov_123"
    }
  end

  before do
    allow(controller).to receive(:session_manager).and_return(session_manager_double)
    # Bypass the browser session requirement since we are explicitly stubbing session manager
    allow(controller).to receive(:require_browser_session!).and_return(true)
  end

  shared_examples "provider callback success" do |action, provider_name|
    let(:provider) { provider_name }

    it "signs in and redirects to decoded redirect_uri with notice" do
      state = Base64.urlsafe_encode64({ redirect_uri: "/dashboard" }.to_json)

      allow(controller).to receive(:extract_user_info).with(provider_name).and_return(user_info)
      allow(controller).to receive(:find_or_create_account_from_social).with(user_info, provider_name).and_return(account)

      get action, params: { state: state }

      expect(response).to redirect_to("/dashboard")
      expect(flash[:notice]).to eq("Successfully signed in with #{provider_name.humanize}")
      expect(session_manager_double).to have_received(:sign_in_account).with(account)
    end

    it "defaults to root path when state missing or invalid" do
      allow(controller).to receive(:extract_user_info).with(provider_name).and_return(user_info)
      allow(controller).to receive(:find_or_create_account_from_social).with(user_info, provider_name).and_return(account)

      get action
      expect(response).to redirect_to("/")

      # invalid state
      get action, params: { state: "not_base64" }
      expect(response).to redirect_to("/")
    end

    it "redirects to login with error when OAuthError is raised" do
      allow(controller).to receive(:extract_user_info).with(provider_name).and_raise(StandardId::OAuthError.new("bad"))

      get action
      expect(response).to redirect_to(controller.login_path)
      expect(flash[:alert]).to eq("Authentication failed: bad")
    end

    it "redirects to login with error when provider passes error param (access_denied)" do
      get action, params: { error: "access_denied" }
      expect(response).to redirect_to(controller.login_path)
      expect(flash[:alert]).to eq("Authentication was cancelled")
    end

    it "redirects to login with error when provider passes error param (invalid_request)" do
      get action, params: { error: "invalid_request" }
      expect(response).to redirect_to(controller.login_path)
      expect(flash[:alert]).to eq("Invalid authentication request")
    end

    it "redirects to login with generic error when provider passes unknown error" do
      get action, params: { error: "some_error" }
      expect(response).to redirect_to(controller.login_path)
      expect(flash[:alert]).to eq("Authentication failed")
    end
  end

  describe "GET #google" do
    include_examples "provider callback success", :google, "google-oauth2"
  end

  describe "GET #apple" do
    include_examples "provider callback success", :apple, "apple"
  end
end
