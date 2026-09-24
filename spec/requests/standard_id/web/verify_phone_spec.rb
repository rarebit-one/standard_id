require "rails_helper"

RSpec.describe "StandardId Web Verify Phone", type: :request do
  describe "GET /verify_phone/start" do
    it "renders the start page" do
      http_get "/verify_phone/start"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("verify phone start")
    end
  end

  describe "POST /verify_phone/start" do
    it "creates a verification challenge and sends code" do
      codes = capture_passwordless_codes

      http_post "/verify_phone/start", params: { phone_number: "+14155550123" }

      expect(codes).to contain_exactly(["+14155550123", kind_of(String)])
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(standard_id_web.login_path)

      ch = StandardId::CodeChallenge.last
      expect(ch).to be_present
      expect(ch.realm).to eq("verification")
      expect(ch.channel).to eq("sms")
      expect(ch.target).to eq("+14155550123")
      expect(ch).to be_active
    end

    it "returns unprocessable when phone invalid" do
      http_post "/verify_phone/start", params: { phone_number: "555-1234" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /verify_phone/confirm" do
    it "shows confirm page for valid code" do
      ch = StandardId::CodeChallenge.create!(
        realm: "verification", channel: "sms", target: "+14155550123",
        code: "123456", expires_at: 10.minutes.from_now
      )

      http_get "/verify_phone/confirm", params: { phone_number: "+14155550123", code: "123456" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("verify phone confirm")
    end

    it "redirects for invalid code" do
      http_get "/verify_phone/confirm", params: { phone_number: "+14155550123", code: "BAD" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid or expired")
    end
  end

  describe "PATCH /verify_phone/confirm" do
    it "marks identifier verified and consumes challenge" do
      account = Account.create!(name: "User", email: "user@example.com")
      idf = StandardId::PhoneNumberIdentifier.create!(account: account, value: "+14155550123")
      ch = StandardId::CodeChallenge.create!(
        realm: "verification", channel: "sms", target: "+14155550123",
        code: "999000", expires_at: 10.minutes.from_now
      )

      http_patch "/verify_phone/confirm", params: { phone_number: "+14155550123", code: "999000" }

      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:notice]).to include("phone number has been verified")

      expect(idf.reload).to be_verified
      expect(ch.reload).to be_used
    end

    it "redirects when invalid" do
      http_patch "/verify_phone/confirm", params: { phone_number: "+14155550123", code: "BAD" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid or expired")
    end
  end
end
