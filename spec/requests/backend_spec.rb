require "rails_helper"

RSpec.describe "Backend", type: :request do
  context "when authenticated" do
    let!(:account) { Account.create!(name: "Spec User", email: "spec@example.com") }
    let!(:browser_session) do
      StandardId::BrowserSession.create!(
        account:,
        user_agent: "RSpec",
        ip_address: "127.0.0.1",
        expires_at: 1.day.from_now
      )
    end

    before { post util_session_path, params: { session_token: browser_session.token } }

    describe "GET /backend" do
      it "returns 200 and renders the dashboard" do
        get backend_root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Backend Dashboard")
      end
    end
  end

  context "when not authenticated" do
    describe "GET /backend" do
      it "returns 302 and redirects to login page" do
        get backend_root_path
        expect(response).to have_http_status(302)
        expect(response.location).to include(standard_id_web.login_path)
      end
    end
  end
end
