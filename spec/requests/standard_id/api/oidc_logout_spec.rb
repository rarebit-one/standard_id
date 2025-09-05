require "rails_helper"

RSpec.describe "StandardId API OIDC Logout", type: :request do
  describe "GET /api/oidc/logout" do
    it "revokes session and returns JSON when no redirect is provided" do
      expect_any_instance_of(StandardId::Web::SessionManager).to receive(:revoke_current_session!).and_call_original

      http_get "/api/oidc/logout"

      expect(response).to have_http_status(:ok)
      body = json_body
      expect(body["message"]).to eq("You have been logged out")
    end

    it "does not redirect to an unallowed URI" do
      allow(StandardId.config).to receive(:allowed_post_logout_redirect_uris).and_return(["https://app.example.com/logged_out"])

      expect_any_instance_of(StandardId::Web::SessionManager).to receive(:revoke_current_session!).and_call_original

      http_get "/api/oidc/logout", params: { post_logout_redirect_uri: "https://evil.example.com/logout" }

      expect(response).to have_http_status(:ok)
      body = json_body
      expect(body["message"]).to eq("You have been logged out")
    end

    it "redirects to an allowed URI" do
      redirect_uri = "https://app.example.com/logged_out"
      allow(StandardId.config).to receive(:allowed_post_logout_redirect_uris).and_return([redirect_uri])

      expect_any_instance_of(StandardId::Web::SessionManager).to receive(:revoke_current_session!).and_call_original

      http_get "/api/oidc/logout", params: { post_logout_redirect_uri: redirect_uri }

      expect(response).to have_http_status(:found)
      expect(response.location).to eq(redirect_uri)
    end

    it "appends state when redirecting to an allowed URI" do
      redirect_uri = "https://app.example.com/logged_out"
      allow(StandardId.config).to receive(:allowed_post_logout_redirect_uris).and_return([redirect_uri])

      expect_any_instance_of(StandardId::Web::SessionManager).to receive(:revoke_current_session!).and_call_original

      http_get "/api/oidc/logout", params: { post_logout_redirect_uri: redirect_uri, state: "abc123" }

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with(redirect_uri)
      expect(URI.parse(response.location).query).to include("state=abc123")
    end
  end
end
