require "rails_helper"

RSpec.describe StandardId::PasswordResetMailer, type: :mailer do
  describe "#reset_email" do
    let(:email) { "user@example.com" }
    let(:reset_url) { "https://example.test/reset_password/confirm?token=abc123" }
    let(:mail) do
      described_class.with(email: email, reset_url: reset_url).reset_email
    end

    before do
      allow(StandardId.config.reset_password).to receive(:mailer_from).and_return("noreply@myapp.com")
      allow(StandardId.config.reset_password).to receive(:mailer_subject).and_return("Reset your password")
    end

    it "sends to the correct email" do
      expect(mail.to).to eq(["user@example.com"])
    end

    it "uses the configured from address" do
      expect(mail.from).to eq(["noreply@myapp.com"])
    end

    it "uses the configured subject" do
      expect(mail.subject).to eq("Reset your password")
    end

    it "includes the reset URL in the HTML body" do
      expect(mail.html_part.body.to_s).to include(reset_url)
    end

    it "includes the reset URL in the text body" do
      expect(mail.text_part.body.to_s).to include(reset_url)
    end
  end
end
