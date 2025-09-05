require "rails_helper"

RSpec.describe "StandardId Web Reset Password Start", type: :request do
  describe "GET /reset_password/start" do
    it "renders the password reset form" do
      http_get "/reset_password/start"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /reset_password/start" do
    let(:account) { Account.create!(email: "user@example.com", name: "Test User") }
    let(:email) { "user@example.com" }

    before do
      identifier = StandardId::EmailIdentifier.create!(account: account, value: email)
      password_credential = StandardId::PasswordCredential.create!(login: email, password: "password123")
      StandardId::Credential.create!(credentialable: password_credential, identifier: identifier)
    end

    context "with valid email" do
      it "sends reset instructions and redirects to login" do
        http_post "/reset_password/start", params: { email: email }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(standard_id_web.login_path)
        expect(flash[:notice]).to eq("If an account with that email exists, we've sent password reset instructions.")
      end
    end

    context "with non-existent email" do
      it "shows success message without revealing email doesn't exist" do
        http_post "/reset_password/start", params: { email: "nonexistent@example.com" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(standard_id_web.login_path)
        expect(flash[:notice]).to eq("If an account with that email exists, we've sent password reset instructions.")
      end
    end

    context "with blank email" do
      it "shows error and re-renders form" do
        http_post "/reset_password/start", params: { email: "" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq("Please enter your email address")
      end
    end

    context "with whitespace-only email" do
      it "shows error and re-renders form" do
        http_post "/reset_password/start", params: { email: "   " }

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq("Please enter your email address")
      end
    end
  end
end
