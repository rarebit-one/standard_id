require "rails_helper"

RSpec.describe StandardId::PasswordResetDeliveryJob, type: :job do
  let(:reset_url_template) { "https://example.test/reset_password/confirm?token={token}" }

  context "when an account with a password credential exists" do
    let!(:account) { Account.create!(email: "user@example.com", name: "User") }
    let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "user@example.com") }
    let!(:password_credential) { StandardId::PasswordCredential.create!(login: "user@example.com", password: "Password1!") }
    let!(:credential) { StandardId::Credential.create!(credentialable: password_credential, identifier: identifier) }

    it "publishes the initiated event with a substituted reset_url, identifier, account, and token" do
      published_events = []
      subscription = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED) do |event|
        published_events << event
      end

      begin
        described_class.new.perform(email: "user@example.com", reset_url_template: reset_url_template)
      ensure
        StandardId::Events.unsubscribe(subscription)
      end

      expect(published_events.length).to eq(1)
      event = published_events.first
      expect(event[:identifier]).to eq("user@example.com")
      expect(event[:account]).to eq(account)
      expect(event[:token]).to be_a(String).and(be_present)
      expect(event[:reset_url]).to start_with("https://example.test/reset_password/confirm?token=")
      expect(event[:reset_url]).not_to include("{token}")
      expect(event[:reset_url]).to end_with(event[:token])
    end

    it "normalises the email for lookup (case/whitespace)" do
      published_events = []
      subscription = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED) do |event|
        published_events << event
      end

      begin
        described_class.new.perform(email: "  USER@Example.COM  ", reset_url_template: reset_url_template)
      ensure
        StandardId::Events.unsubscribe(subscription)
      end

      expect(published_events.first[:identifier]).to eq("user@example.com")
    end
  end

  context "when no account matches the email" do
    it "does not publish the event and does not raise" do
      published_events = []
      subscription = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED) do |event|
        published_events << event
      end

      begin
        expect {
          described_class.new.perform(email: "missing@example.com", reset_url_template: reset_url_template)
        }.not_to raise_error
      ensure
        StandardId::Events.unsubscribe(subscription)
      end

      expect(published_events).to be_empty
    end
  end

  context "when the account has no password credential" do
    let!(:account) { Account.create!(email: "nopw@example.com", name: "No Password") }
    let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "nopw@example.com") }

    it "does not publish the event" do
      published_events = []
      subscription = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED) do |event|
        published_events << event
      end

      begin
        described_class.new.perform(email: "nopw@example.com", reset_url_template: reset_url_template)
      ensure
        StandardId::Events.unsubscribe(subscription)
      end

      expect(published_events).to be_empty
    end
  end
end
