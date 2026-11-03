require "rails_helper"

RSpec.describe StandardId::Passwordless::EmailStrategy do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  subject(:strategy) { described_class.new(request) }

  describe "#validate_username!" do
    it "accepts a valid email" do
      expect { strategy.send(:validate_username!, "user@example.com") }.not_to raise_error
    end

    it "rejects an invalid email" do
      expect { strategy.send(:validate_username!, "invalid") }.to raise_error(StandardId::InvalidRequestError)
    end
  end

  describe "#start!" do
    it "creates a challenge and publishes the code for delivery" do
      codes = capture_passwordless_codes

      challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(codes).to contain_exactly(["user@example.com", kind_of(String)])
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

    it "clamps code_length up to the 4-digit floor for small positive values" do
      allow(StandardId.config.passwordless).to receive(:code_length).and_return(2)

      challenge = strategy.start!(connection: "email", username: "user@example.com")
      expect(challenge.code).to match(/\A\d{4}\z/)
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

        challenge = strategy.start!(connection: "email", username: "user@example.com")
        expect(challenge).to be_persisted
      end

      it "proceeds when validator returns false" do
        StandardId.config.passwordless.username_validator = ->(_username, _connection) { false }

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

        strategy.start!(connection: "email", username: "user@example.com")
      end
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

      identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: email)
      expect(identifier).to be_present
      expect(identifier.account).to eq(account)
      expect(identifier).to be_verified
    end
  end

  describe "registered-TLD check on #start!" do
    %w[jaryl@rarebit.ome user@example.con user@example.invalidtld].each do |email|
      it "rejects #{email} before any code is generated or sent" do
        events = capture_passwordless_start_events

        expect {
          strategy.start!(connection: "email", username: email)
        }.to raise_error(StandardId::InvalidRequestError, "#{email.split("@").last} isn't a valid e-mail domain. Check the address.")

        expect(events).to be_empty
        expect(StandardId::CodeChallenge.count).to eq(0)
      end
    end

    %w[user@rarebit.one user@example.sg user@example.co.uk user@example.app user@example.xn--p1ai].each do |email|
      it "accepts #{email}" do
        expect(strategy.start!(connection: "email", username: email)).to be_persisted
      end
    end

    it "runs before the host's username_validator, which still runs after it" do
      validator = ->(_username, _connection_type) { nil }
      allow(StandardId.config.passwordless).to receive(:username_validator).and_return(validator)
      allow(validator).to receive(:call).and_call_original

      expect { strategy.start!(connection: "email", username: "user@rarebit.ome") }
        .to raise_error(StandardId::InvalidRequestError, /isn't a valid e-mail domain/)
      expect(validator).not_to have_received(:call)

      strategy.start!(connection: "email", username: "user@rarebit.one")
      expect(validator).to have_received(:call).with("user@rarebit.one", "email")
    end

    it "accepts a default special-use TLD (dev/test addresses)" do
      expect(strategy.start!(connection: "email", username: "dev@example.test")).to be_persisted
    end

    it "is skipped when email.require_registered_tld is off" do
      allow(StandardId.config.email).to receive(:require_registered_tld).and_return(false)

      expect(strategy.start!(connection: "email", username: "user@rarebit.ome")).to be_persisted
    end

    it "does not apply when verifying or looking up an account" do
      expect { strategy.find_account("user@rarebit.ome") }.not_to raise_error
    end
  end
end
