require "rails_helper"

RSpec.describe "StandardId Web Logout (Inertia clear_history)", :inertia, type: :request do
  # LogoutController#create passes inertia: { clear_history: true } when the
  # host uses Inertia (use_inertia? is true). This sets session[:_inertia_clear_history]
  # via the InertiaDouble#redirect_to override, which the next Inertia render
  # consumes to set clearHistory: true in the page JSON, rotating the history key.
  describe "POST /logout" do
    context "when authenticated" do
      let!(:account) { Account.create!(name: "Inertia User", email: "inertia-logout@example.com") }
      let!(:browser_session) do
        StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1",
                                           user_agent: "RSpec", expires_at: 1.day.from_now)
      end

      before { post util_session_path, params: { session_token: browser_session.token } }

      it "sets the Inertia clear_history flag in session" do
        http_post "/logout"

        expect(session[:_inertia_clear_history]).to be(true)
      end

      it "still redirects to the logout destination with a notice" do
        http_post "/logout", params: { redirect_uri: "/goodbye" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/goodbye")
        expect(flash[:notice]).to eq("Successfully signed out")
      end
    end

    context "when not authenticated (redirect_if_not_authenticated branch)" do
      it "does not set the Inertia clear_history flag" do
        # The unauthenticated redirect is issued by redirect_if_not_authenticated,
        # not by #create, so no inertia: option is passed.
        http_post "/logout"

        expect(session[:_inertia_clear_history]).to be_nil
      end
    end
  end
end

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

      it "rejects cross-host redirect_uri not in the allow list" do
        http_post "/logout", params: { redirect_uri: "https://evil.example.com/phish" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
      end

      it "rejects Array-shaped redirect_uri instead of crashing on redirect_to" do
        http_post "/logout", params: { redirect_uri: ["/a", "/b"] }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
      end
    end
  end
end
