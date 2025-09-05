require "rails_helper"

RSpec.describe "Admin", type: :request do
  let(:account) { Account.create!(email: "test@example.com", name: "Test User") }

  context "when authenticated" do
    describe "GET /admin" do
      it "returns 200 and renders the dashboard" do
        as_user(account) do
          http_get admin_root_path
        end
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Admin Dashboard")
      end
    end
  end

  context "when not authenticated" do
    describe "GET /admin" do
      it "returns 302 and redirects to login page" do
        http_get admin_root_path
        expect(response).to have_http_status(302)
        expect(response.location).to include(standard_id_web.login_path)
      end
    end
  end
end
