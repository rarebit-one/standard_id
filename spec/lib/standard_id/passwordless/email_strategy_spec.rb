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

    it "generates a 6-digit code by default" do
      challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(challenge.code).to match(/\A\d{6}\z/)
    end

    it "honors config.passwordless.code_length for longer codes" do
      allow(StandardId.config.passwordless).to receive(:code_length).and_return(8)

      challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(challenge.code).to match(/\A\d{8}\z/)
    end

    it "clamps code_length into a sane range (ignores 0/negative)" do
      allow(StandardId.config.passwordless).to receive(:code_length).and_return(0)

      challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(challenge.code).to match(/\A\d{6}\z/)
    end

    it "clamps code_length into a sane range (ignores absurdly large values)" do
      allow(StandardId.config.passwordless).to receive(:code_length).and_return(50)

      challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(challenge.code.length).to eq(10)
    end

    it "invalidates previous active challenges for the same target" do
      first_challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(first_challenge).to be_active

      second_challenge = strategy.start!(connection: "email", username: "user@example.com")

      expect(first_challenge.reload).to be_used
      expect(second_challenge).to be_active
    end

    it "does not invalidate challenges for other targets" do
      other_challenge = strategy.start!(connection: "email", username: "other@example.com")
      strategy.start!(connection: "email", username: "user@example.com")

      expect(other_challenge.reload).to be_active
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

      it "proceeds when validator returns false" do
        StandardId.config.passwordless.username_validator = ->(_username, _connection) { false }
        allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)

        challenge = strategy.start!(connection: "email", username: "user@example.com")
        expect(challenge).to be_persisted
      end

      it "rejects when validator returns an error message and does not create a challenge" do
        StandardId.config.passwordless.username_validator = ->(_username, _connection) {
          "Please enter a valid email address"
        }

        expect {
          strategy.start!(connection: "email", username: "user@bad-domain.xyz")
        }.to raise_error(StandardId::InvalidRequestError, "Please enter a valid email address")
          .and change(StandardId::CodeChallenge, :count).by(0)
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
