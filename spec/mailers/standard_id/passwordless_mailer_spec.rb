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
      allow(StandardId.config.passwordless).to receive(:code_ttl).and_return(600)
    end

    it "sends to the correct email" do
      expect(mail.to).to eq(["user@example.com"])
    end

    it "uses the configured from address" do
      expect(mail.from).to eq(["noreply@myapp.com"])
    end

    it "uses the default subject" do
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
        StandardId.config.passwordless.mailer_subject = "Login code"
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

  describe "i18n" do
    let(:mail) { described_class.with(email: "user@example.com", otp_code: "123456").otp_email }

    it "takes the sign-in subject and copy from standard_id.passwordless_mailer.otp_email.* when mailer_subject is unassigned" do
      I18n.t("standard_id") # load the locale files first, or they overwrite the stored keys
      I18n.backend.store_translations(:en, standard_id: { passwordless_mailer: { otp_email: {
        subject: "Your ACME sign-in code", intro: "Here is your ACME code:"
      } } })

      expect(mail.subject).to eq("Your ACME sign-in code")
      expect(mail.text_part.body.to_s).to include("Here is your ACME code:")
    ensure
      I18n.backend.reload!
    end

    it "lets an assigned c.passwordless.mailer_subject win over the i18n subject" do
      StandardId.config.passwordless.mailer_subject = "Your Jumpdrive sign-in code"

      expect(mail.subject).to eq("Your Jumpdrive sign-in code")
    end

    it "uses expires_in_minutes when given" do
      mail = described_class.with(email: "user@example.com", otp_code: "123456", expires_in_minutes: 1).otp_email

      expect(mail.text_part.body.to_s).to include("expire in 1 minute.")
    end
  end

  describe "#verification_email" do
    let(:mail) do
      described_class.with(email: "user@example.com", otp_code: "654321", realm: "verification", expires_in_minutes: 10).verification_email
    end

    it "is addressed and coded like the sign-in email" do
      expect(mail.to).to eq(["user@example.com"])
      expect(mail.html_part.body.to_s).to include("654321")
      expect(mail.text_part.body.to_s).to include("654321")
      expect(mail.text_part.body.to_s).to include("10 minutes")
    end

    it "never uses the sign-in subject or copy" do
      StandardId.config.passwordless.mailer_subject = "Your sign-in code"

      expect(mail.subject).to eq("Your verification code")
      [mail.html_part.body.to_s, mail.text_part.body.to_s].each do |body|
        expect(body).to include("Use the following code to complete your verification:")
        expect(body).not_to match(/sign in/i)
      end
    end

    it "takes subject and copy from standard_id.passwordless_mailer.verification_email.*" do
      I18n.t("standard_id") # load the locale files first, or they overwrite the stored keys
      I18n.backend.store_translations(:en, standard_id: { passwordless_mailer: { verification_email: {
        subject: "Confirm your ACME email", intro: "Confirm it with:"
      } } })

      expect(mail.subject).to eq("Confirm your ACME email")
      expect(mail.html_part.body.to_s).to include("Confirm it with:")
    ensure
      I18n.backend.reload!
    end
  end

  describe "under a locale the gem has no translations for" do
    around do |example|
      original = I18n.available_locales
      I18n.available_locales = original | [:"zh-SG"]
      I18n.with_locale(:"zh-SG") { example.run }
    ensure
      I18n.available_locales = original
    end

    it "falls back to the English copy rather than rendering missing translations" do
      mails = [
        described_class.with(email: "user@example.com", otp_code: "123456").otp_email,
        described_class.with(email: "user@example.com", otp_code: "123456", realm: "verification").verification_email
      ]

      expect(mails.map(&:subject)).to eq(["Your sign-in code", "Your verification code"])
      mails.each do |mail|
        [mail.html_part.body.to_s, mail.text_part.body.to_s].each do |body|
          expect(body).not_to match(/translation missing/i)
          expect(body).to include("This code will expire in 10 minutes.")
        end
      end
    end

    it "uses the host's translation for that locale when there is one" do
      I18n.t("standard_id")
      I18n.backend.store_translations(:"zh-SG", standard_id: { passwordless_mailer: { verification_email: {
        subject: "您的验证码"
      } } })

      mail = described_class.with(email: "user@example.com", otp_code: "123456").verification_email

      expect(mail.subject).to eq("您的验证码")
      expect(mail.text_part.body.to_s).to include("Use the following code to complete your verification:")
    ensure
      I18n.backend.reload!
    end
  end
end
