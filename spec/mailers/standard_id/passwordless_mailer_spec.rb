require "rails_helper"

RSpec.describe StandardId::PasswordlessMailer, type: :mailer do
  describe "#otp_email" do
    let(:email) { "user@example.com" }
    let(:otp_code) { "123456" }
    let(:mail) do
      described_class.with(email: email, otp_code: otp_code).otp_email
    end

    before do
      allow(StandardId.config.passwordless).to receive(:mailer_from).and_return("noreply@myapp.com")
      allow(StandardId.config.passwordless).to receive(:mailer_subject).and_return("Your sign-in code")
      allow(StandardId.config.passwordless).to receive(:code_ttl).and_return(600)
    end

    it "sends to the correct email" do
      expect(mail.to).to eq(["user@example.com"])
    end

    it "uses the configured from address" do
      expect(mail.from).to eq(["noreply@myapp.com"])
    end

    it "uses the configured subject" do
      expect(mail.subject).to eq("Your sign-in code")
    end

    it "includes the OTP code in the HTML body" do
      expect(mail.html_part.body.to_s).to include("123456")
    end

    it "includes the OTP code in the text body" do
      expect(mail.text_part.body.to_s).to include("123456")
    end

    it "includes the expiry time in the HTML body" do
      expect(mail.html_part.body.to_s).to include("10 minutes")
    end

    it "includes the expiry time in the text body" do
      expect(mail.text_part.body.to_s).to include("10 minutes")
    end

    context "with custom configuration" do
      before do
        allow(StandardId.config.passwordless).to receive(:mailer_from).and_return("auth@custom.com")
        allow(StandardId.config.passwordless).to receive(:mailer_subject).and_return("Login code")
        allow(StandardId.config.passwordless).to receive(:code_ttl).and_return(300)
      end

      it "uses the custom from address" do
        expect(mail.from).to eq(["auth@custom.com"])
      end

      it "uses the custom subject" do
        expect(mail.subject).to eq("Login code")
      end

      it "reflects the custom TTL in the body" do
        expect(mail.html_part.body.to_s).to include("5 minutes")
        expect(mail.text_part.body.to_s).to include("5 minutes")
      end
    end
  end
end
