require "rails_helper"

RSpec.describe "StandardId Web Verify Email", type: :request do
  describe "GET /verify_email/start" do
    it "renders the start page" do
      http_get "/verify_email/start"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("verify email start")
    end
  end

  describe "POST /verify_email/start" do
    it "creates a verification challenge and sends code" do
      codes = capture_passwordless_codes

      http_post "/verify_email/start", params: { email: "user@example.com" }

      expect(codes).to contain_exactly(["user@example.com", kind_of(String)])
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(standard_id_web.login_path)

      ch = StandardId::CodeChallenge.last
      expect(ch).to be_present
      expect(ch.realm).to eq("verification")
      expect(ch.channel).to eq("email")
      expect(ch.target).to eq("user@example.com")
      expect(ch).to be_active
    end

    it "returns unprocessable when email missing" do
      http_post "/verify_email/start", params: { email: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns unprocessable, issuing nothing, for a malformed email" do
      codes = capture_passwordless_codes

      http_post "/verify_email/start", params: { email: "not-an-email" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(codes).to be_empty
      expect(StandardId::CodeChallenge.where(realm: "verification").count).to eq(0)
    end

    it "is delivered by the bundled mailer when c.passwordless.delivery is :built_in" do
      allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)

      expect {
        http_post "/verify_email/start", params: { email: "user@example.com" }
      }.to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)
    end

    it "returns the retry cooldown as the 422 body and flash" do
      allow(StandardId::Passwordless).to receive(:retry_delay).and_return(30)
      http_post "/verify_email/start", params: { email: "user@example.com" }
      expect(response).to have_http_status(:see_other)

      http_post "/verify_email/start", params: { email: "user@example.com" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/\APlease wait \d+ seconds? before requesting another code\z/)
      expect(flash[:alert]).to eq(response.body)
    end

    it "returns the username_validator's message as the 422 body and flash" do
      allow(StandardId.config.passwordless).to receive(:username_validator)
        .and_return(->(_username, _channel) { "Disposable addresses are not allowed" })

      http_post "/verify_email/start", params: { email: "user@example.com" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to eq("Disposable addresses are not allowed")
      expect(flash[:alert]).to eq("Disposable addresses are not allowed")
    end

    it "returns the format error as the 422 body" do
      http_post "/verify_email/start", params: { email: "not-an-email" }

      expect(response.body).to eq("Invalid email format")
    end
  end

  describe "GET /verify_email/confirm" do
    it "shows confirm page for valid code" do
      ch = StandardId::CodeChallenge.create!(
        realm: "verification", channel: "email", target: "user@example.com",
        code: "123456", expires_at: 10.minutes.from_now
      )

      http_get "/verify_email/confirm", params: { email: "user@example.com", code: "123456" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("verify email confirm")
    end

    it "redirects for invalid code" do
      http_get "/verify_email/confirm", params: { email: "user@example.com", code: "BAD" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid or expired")
    end
  end

  describe "PATCH /verify_email/confirm" do
    it "marks identifier verified and consumes challenge" do
      account = Account.create!(name: "User", email: "user@example.com")
      idf = StandardId::EmailIdentifier.create!(account: account, value: "user@example.com")
      ch = StandardId::CodeChallenge.create!(
        realm: "verification", channel: "email", target: "user@example.com",
        code: "999000", expires_at: 10.minutes.from_now
      )

      http_patch "/verify_email/confirm", params: { email: "user@example.com", code: "999000" }

      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:notice]).to include("email has been verified")

      expect(idf.reload).to be_verified
      expect(ch.reload).to be_used
    end

    it "redirects when invalid" do
      http_patch "/verify_email/confirm", params: { email: "user@example.com", code: "BAD" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid or expired")
    end
  end
end
