require "rails_helper"

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
