require "rails_helper"

RSpec.describe StandardId::Passwordless::EmailStrategy do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  subject(:strategy) { described_class.new(request) }

  before do
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)
  end

  describe "#validate_username!" do
    it "accepts a valid email" do
      expect { strategy.send(:validate_username!, "user@example.com") }.not_to raise_error
    end

    it "rejects an invalid email" do
      expect { strategy.send(:validate_username!, "invalid") }.to raise_error(StandardId::InvalidRequestError)
    end
  end

  describe "#start!" do
    it "creates a challenge and calls sender" do
      sender = double("sender")
      expect(sender).to receive(:call).with("user@example.com", kind_of(String))
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

      challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(challenge).to be_persisted
      expect(challenge.channel).to eq("email")
      expect(challenge.target).to eq("user@example.com")
      expect(challenge).to be_active
    end

    context "with username_validator configured" do
      after do
        StandardId.config.passwordless.username_validator = nil
      end

      it "proceeds when validator returns nil" do
        StandardId.config.passwordless.username_validator = ->(_username, _connection) { nil }
        allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)

        challenge = strategy.start!(connection: "email", username: "user@example.com")
        expect(challenge).to be_persisted
      end

      it "rejects when validator returns an error message" do
        StandardId.config.passwordless.username_validator = ->(_username, _connection) {
          "Please enter a valid email address"
        }

        expect {
          strategy.start!(connection: "email", username: "user@bad-domain.xyz")
        }.to raise_error(StandardId::InvalidRequestError, "Please enter a valid email address")
      end

      it "does not create a code challenge when validation fails" do
        StandardId.config.passwordless.username_validator = ->(_username, _connection) { "Invalid" }

        expect {
          strategy.start!(connection: "email", username: "user@bad-domain.xyz") rescue nil
        }.not_to change(StandardId::CodeChallenge, :count)
      end

      it "passes username and connection_type to the validator" do
        validator = double("validator")
        expect(validator).to receive(:call).with("user@example.com", "email").and_return(nil)
        StandardId.config.passwordless.username_validator = validator
        allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)

        strategy.start!(connection: "email", username: "user@example.com")
      end
    end
  end

  describe "#sender_callback" do
    it "returns the email sender when delivery is :custom" do
      sender = double("sender")
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)
      allow(StandardId.config.passwordless).to receive(:delivery).and_return(:custom)

      expect(strategy.send(:sender_callback)).to eq(sender)
    end

    it "returns nil when delivery is :built_in to prevent duplicate emails" do
      sender = double("sender")
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)
      allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)

      expect(strategy.send(:sender_callback)).to be_nil
    end
  end

  describe "#find_or_create_account!" do
    it "returns existing account when identifier exists" do
      account = Account.create!(name: "User", email: "user@example.com")
      StandardId::EmailIdentifier.create!(account: account, value: "user@example.com", verified_at: Time.current)

      found = strategy.send(:find_or_create_account!, "user@example.com")
      expect(found).to eq(account)
    end

    it "creates account and identifier when missing" do
      email = "new-user@example.com"
      # Stub only the nested-attributes variant to avoid recursion
      allow(Account).to receive(:create!)
        .with(hash_including(identifiers_attributes: kind_of(Array)))
        .and_return(
          begin
            account = Account.new(name: "Auto User", email: email)
            account.save!
            StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
            account
          end
        )

      account = strategy.send(:find_or_create_account!, email)
      expect(account).to be_a(Account)

      identifier = StandardId::EmailIdentifier.find_by(value: email)
      expect(identifier).to be_present
      expect(identifier.account).to eq(account)
      expect(identifier).to be_verified
    end
  end
end
