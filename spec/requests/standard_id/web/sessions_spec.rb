require "rails_helper"

RSpec.describe "StandardId Web Sessions (Inertia clear_history)", :inertia, type: :request do
  # SessionsController#destroy passes inertia: { clear_history: true } only when
  # revoking the current session (which signs the user out). Revoking another
  # session does not sign the current user out, so no clear_history is needed.
  let!(:account) { Account.create!(name: "Inertia Session User", email: "inertia-sessions@example.com") }
  let!(:current_browser_session) do
    StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1",
                                       user_agent: "RSpec", expires_at: 1.day.from_now)
  end

  before { post util_session_path, params: { session_token: current_browser_session.token } }

  describe "DELETE /sessions/:id" do
    context "when deleting the current session" do
      it "sets the Inertia clear_history flag in session" do
        http_delete "/sessions/#{current_browser_session.id}"

        expect(session[:_inertia_clear_history]).to be(true)
      end

      it "still redirects to root with a notice" do
        http_delete "/sessions/#{current_browser_session.id}"

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
        expect(flash[:notice]).to eq("Session revoked. You have been signed out.")
      end
    end

    context "when deleting another session" do
      let!(:other_session) do
        StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1",
                                           user_agent: "RSpec Other", expires_at: 1.day.from_now)
      end

      it "does not set the Inertia clear_history flag (user remains signed in)" do
        http_delete "/sessions/#{other_session.id}"

        expect(session[:_inertia_clear_history]).to be_nil
      end
    end
  end
end

RSpec.describe "StandardId Web Sessions", type: :request do
  let!(:account) { Account.create!(name: "Spec User", email: "spec@example.com") }
  let!(:current_browser_session) do
    StandardId::BrowserSession.create!(
      account: account,
      user_agent: "RSpec",
      ip_address: "127.0.0.1",
      expires_at: 1.day.from_now
    )
  end

  before do
    post util_session_path, params: { session_token: current_browser_session.token }
  end

  describe "GET /sessions" do
    it "renders list of active sessions and current session" do
      other_session = StandardId::BrowserSession.create!(
        account: account,
        user_agent: "RSpec Other",
        ip_address: "127.0.0.1",
        expires_at: 1.day.from_now
      )

      http_get "/sessions"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Active Sessions")
      expect(response.body).to include(current_browser_session.id.to_s)
      expect(response.body).to include(other_session.id.to_s)
    end
  end

  describe "DELETE /sessions/:id" do
    context "when deleting current session" do
      it "revokes session and redirects to root with notice" do
        http_delete "/sessions/#{current_browser_session.id}"

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
        expect(flash[:notice]).to eq("Session revoked. You have been signed out.")
        expect(current_browser_session.reload).to be_revoked
      end
    end

    context "when deleting another session" do
      it "revokes it and redirects back to sessions list" do
        other_session = StandardId::BrowserSession.create!(
          account: account,
          user_agent: "RSpec Other",
          ip_address: "127.0.0.1",
          expires_at: 1.day.from_now
        )

        http_delete "/sessions/#{other_session.id}"

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(standard_id_web.sessions_path)
        expect(flash[:notice]).to eq("Session revoked successfully")
        expect(other_session.reload).to be_revoked
      end
    end

    context "when session is not found" do
      it "redirects back to sessions with alert" do
        someone_else = Account.create!(name: "Other", email: "other@example.com")
        foreign_session = StandardId::BrowserSession.create!(
          account: someone_else,
          user_agent: "RSpec Foreign",
          ip_address: "127.0.0.1",
          expires_at: 1.day.from_now
        )

        http_delete "/sessions/#{foreign_session.id}"

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(standard_id_web.sessions_path)
        expect(flash[:alert]).to eq("Session not found")
      end
    end
  end
end

RSpec.describe "StandardId Web Sessions (unauthenticated)", type: :request do
  # No sign-in: the authentication guard raises NotAuthenticatedError. The web
  # base controller must rescue it and bounce to login — previously this raise
  # was unhandled and surfaced as a 500.
  it "redirects GET /sessions to the login page instead of raising a 500" do
    http_get "/sessions"

    expect(response).to have_http_status(:found)
    expect(response.headers["Location"]).to include("/login")
  end
end
