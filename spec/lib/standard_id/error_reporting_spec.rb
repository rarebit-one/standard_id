require "rails_helper"

RSpec.describe StandardId::ErrorReporting do
  let(:error) { RuntimeError.new("subscriber blew up") }

  describe ".report" do
    it "reports to Rails.error by default, exactly as the engine always has" do
      allow(Rails.error).to receive(:report)

      described_class.report(error, event: "standard_id.social.account.linked")

      expect(Rails.error).to have_received(:report).with(error, handled: true, source: "standard_id")
    end

    it "sends the error and context to a configured error_reporter instead" do
      reported = []
      StandardId.config.error_reporter = ->(e, context) { reported << [e, context] }
      allow(Rails.error).to receive(:report)

      described_class.report(error, action: "rehash")

      expect(reported).to eq([[error, { action: "rehash", source: "standard_id", handled: true }]])
      expect(Rails.error).not_to have_received(:report)
    end

    it "logs an error_reporter's own error and falls back to Rails.error" do
      StandardId.config.error_reporter = ->(_e, _context) { raise ArgumentError, "reporter broken" }
      allow(Rails.error).to receive(:report)
      allow(Rails.logger).to receive(:error)

      expect { described_class.report(error, action: "rehash") }.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(/error_reporter raised ArgumentError: reporter broken/)
      expect(Rails.error).to have_received(:report).with(error, handled: true, source: "standard_id")
    end
  end

  describe "the call sites" do
    let(:account) { Account.create!(name: "Reporter", email: "reporter@example.com") }
    let(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "reporter@example.com") }
    let(:credential) do
      StandardId::PasswordCredential.create!(login: "reporter@example.com", password: "Password1!").tap do |c|
        StandardId::Credential.create!(credentialable: c, identifier: identifier)
      end
    end

    it "routes a failing CREDENTIAL_PASSWORD_REHASHED subscriber through the error_reporter" do
      reported = []
      StandardId.config.error_reporter = ->(e, context) { reported << [e.message, context] }
      subscriber = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) { raise "boom" }

      credential.send(:publish_password_rehashed, BCrypt::Engine::MIN_COST)

      expect(reported.size).to eq(1)
      expect(reported.first.first).to eq("boom")
      expect(reported.first.last).to include(source: "standard_id", handled: true, action: /CREDENTIAL_PASSWORD_REHASHED/)
    ensure
      StandardId::Events.unsubscribe(subscriber) if subscriber
    end

    it "keeps a password rehash going when the error_reporter itself raises" do
      StandardId.config.error_reporter = ->(_e, _context) { raise "reporter broken" }
      allow(Rails.error).to receive(:report)
      subscriber = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) { raise "boom" }

      expect { credential.send(:publish_password_rehashed, BCrypt::Engine::MIN_COST) }.not_to raise_error
      expect(Rails.error).to have_received(:report).with(an_object_having_attributes(message: "boom"), handled: true, source: "standard_id")
    ensure
      StandardId::Events.unsubscribe(subscriber) if subscriber
    end
  end
end
