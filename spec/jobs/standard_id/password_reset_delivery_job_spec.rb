require "rails_helper"

RSpec.describe StandardId::PasswordResetDeliveryJob, type: :job do
  let(:reset_url_template) { "https://example.test/reset_password/confirm?token={token}" }

  before do
    allow(StandardId.config.reset_password).to receive(:delivery).and_return(:built_in)
  end

  context "when an account with a password credential exists" do
    let!(:account) { Account.create!(email: "user@example.com", name: "User") }
    let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "user@example.com") }
    let!(:password_credential) { StandardId::PasswordCredential.create!(login: "user@example.com", password: "Password1!") }
    let!(:credential) { StandardId::Credential.create!(credentialable: password_credential, identifier: identifier) }

    it "delivers the reset email with a substituted token and publishes the initiated event" do
      mailer_double = double("ActionMailer::MessageDelivery")
      mail_double = double("Mail::Message")

      captured_url = nil
      expect(StandardId::PasswordResetMailer).to receive(:with) do |kwargs|
        captured_url = kwargs[:reset_url]
        expect(kwargs[:email]).to eq("user@example.com")
        mailer_double
      end
      expect(mailer_double).to receive(:reset_email).and_return(mail_double)
      expect(mail_double).to receive(:deliver_later)

      published_events = []
      subscription = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED) do |event|
        published_events << event
      end

      begin
        described_class.new.perform(email: "user@example.com", reset_url_template: reset_url_template)
      ensure
        StandardId::Events.unsubscribe(subscription)
      end

      expect(captured_url).to start_with("https://example.test/reset_password/confirm?token=")
      expect(captured_url).not_to include("{token}")
      expect(published_events.first[:identifier]).to eq("user@example.com")
      expect(published_events.first[:account]).to eq(account)
    end

    it "normalises the email for lookup (case/whitespace)" do
      mailer_double = double("ActionMailer::MessageDelivery", reset_email: double(deliver_later: true))
      expect(StandardId::PasswordResetMailer).to receive(:with).with(hash_including(email: "user@example.com")).and_return(mailer_double)

      described_class.new.perform(email: "  USER@Example.COM  ", reset_url_template: reset_url_template)
    end
  end

  context "when no account matches the email" do
    it "does not deliver email and does not raise" do
      expect(StandardId::PasswordResetMailer).not_to receive(:with)

      expect {
        described_class.new.perform(email: "missing@example.com", reset_url_template: reset_url_template)
      }.not_to raise_error
    end
  end

  context "when the account has no password credential" do
    let!(:account) { Account.create!(email: "nopw@example.com", name: "No Password") }
    let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "nopw@example.com") }

    it "does not deliver email" do
      expect(StandardId::PasswordResetMailer).not_to receive(:with)

      described_class.new.perform(email: "nopw@example.com", reset_url_template: reset_url_template)
    end
  end

  context "when delivery is :custom" do
    before do
      allow(StandardId.config.reset_password).to receive(:delivery).and_return(:custom)
    end

    it "is a no-op (host app handles delivery via event subscriber)" do
      expect(StandardId::PasswordResetMailer).not_to receive(:with)

      described_class.new.perform(email: "user@example.com", reset_url_template: reset_url_template)
    end
  end
end
