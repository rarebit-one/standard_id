require "rails_helper"

RSpec.describe "Admin::AccountsController", type: :request do
  let(:account) { Account.create!(email: "test@example.com", name: "Test User") }

  describe "GET /admin/accounts" do
    it "returns a 200 and renders the accounts page" do
      as_user(account) do
        http_get "/admin/accounts"
      end

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Accounts")
    end
  end

  describe "GET /admin/accounts/:id" do
    it "returns a 200 and renders account details" do
      test_account = Account.create!(name: "Request Spec User", email: "requestspec@example.com")

      as_user(account) do
        http_get "/admin/accounts/#{test_account.id}"
      end

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Account Details")
    end
  end
end
