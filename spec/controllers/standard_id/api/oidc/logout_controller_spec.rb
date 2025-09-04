require "rails_helper"

RSpec.describe StandardId::Api::Oidc::LogoutController, type: :controller do
  routes { StandardId::ApiEngine.routes }

  let(:session_manager) { instance_double(StandardId::Web::SessionManager) }

  before do
    allow(controller).to receive(:session_manager).and_return(session_manager)
  end

  around do |example|
    original_allowlist = StandardId.config.allowed_post_logout_redirect_uris
    begin
      example.run
    ensure
      StandardId.config.allowed_post_logout_redirect_uris = original_allowlist
    end
  end

  describe "GET #show" do
    it "revokes session and returns JSON when no redirect is provided" do
      expect(session_manager).to receive(:revoke_current_session!).once

      get :show

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["message"]).to eq("You have been logged out")
    end

    it "does not redirect to an unallowed URI" do
      StandardId.config.allowed_post_logout_redirect_uris = ["https://app.example.com/logged_out"]
      expect(session_manager).to receive(:revoke_current_session!).once

      get :show, params: { post_logout_redirect_uri: "https://evil.example.com/logout" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["message"]).to eq("You have been logged out")
    end

    it "redirects to an allowed URI" do
      redirect_uri = "https://app.example.com/logged_out"
      StandardId.config.allowed_post_logout_redirect_uris = [redirect_uri]
      expect(session_manager).to receive(:revoke_current_session!).once

      get :show, params: { post_logout_redirect_uri: redirect_uri }

      expect(response).to have_http_status(:found)
      expect(response.location).to eq(redirect_uri)
    end

    it "appends state when redirecting to an allowed URI" do
      redirect_uri = "https://app.example.com/logged_out"
      StandardId.config.allowed_post_logout_redirect_uris = [redirect_uri]
      expect(session_manager).to receive(:revoke_current_session!).once

      get :show, params: { post_logout_redirect_uri: redirect_uri, state: "abc123" }

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with(redirect_uri)
      expect(URI.parse(response.location).query).to include("state=abc123")
    end
  end
end
