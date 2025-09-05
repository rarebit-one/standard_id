require "rails_helper"

RSpec.describe "StandardId Web Logout", type: :request do
  describe "POST /logout" do
    context "when authenticated" do
      it "revokes current session and redirects to provided redirect_uri with notice" do
        account = Account.create!(name: "User", email: "user@example.com")
        browser_session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now)
        post util_session_path, params: { session_token: browser_session.token }

        http_post "/logout", params: { redirect_uri: "/goodbye" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/goodbye")
        expect(flash[:notice]).to eq("Successfully signed out")
        expect(browser_session.reload).to be_revoked
      end

      it "revokes current session and redirects to root when no redirect_uri" do
        account = Account.create!(name: "User", email: "user2@example.com")
        browser_session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now)
        post util_session_path, params: { session_token: browser_session.token }

        http_post "/logout"

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
        expect(flash[:notice]).to eq("Successfully signed out")
        expect(browser_session.reload).to be_revoked
      end
    end

    context "when not authenticated" do
      it "redirects to provided redirect_uri and does not revoke session" do
        http_post "/logout", params: { redirect_uri: "/landing" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/landing")
      end

      it "redirects to root when no redirect_uri" do
        http_post "/logout"

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
      end
    end
  end
end
