require "rails_helper"

RSpec.describe StandardId::Passwordless::SmsStrategy do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  subject(:strategy) { described_class.new(request) }

  before do
    allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(nil)
  end

  describe "#validate_username!" do
    it "accepts a valid E.164 phone number" do
      expect { strategy.send(:validate_username!, "+14155550123") }.not_to raise_error
    end

    it "rejects an invalid phone number" do
      expect { strategy.send(:validate_username!, "555-1234") }.to raise_error(StandardId::InvalidRequestError)
    end
  end

  describe "#start!" do
    it "creates a challenge and calls sender" do
      sender = double("sender")
      expect(sender).to receive(:call).with("+14155550123", kind_of(String))
      allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(sender)

      challenge = strategy.start!(connection: "sms", username: "+14155550123")
      expect(challenge).to be_persisted
      expect(challenge.channel).to eq("sms")
      expect(challenge.target).to eq("+14155550123")
      expect(challenge).to be_active
    end
  end

  describe "#find_or_create_account!" do
    it "returns existing account when phone identifier exists" do
      account = Account.create!(name: "User", email: "user@example.com")
      StandardId::PhoneNumberIdentifier.create!(account: account, value: "+14155550123", verified_at: Time.current)

      found = strategy.send(:find_or_create_account!, "+14155550123")
      expect(found).to eq(account)
    end

    it "creates account and phone identifier when missing" do
      phone = "+14155550123"
      # Stub only the nested-attributes variant to avoid recursion
      allow(Account).to receive(:create!)
        .with(hash_including(identifiers_attributes: kind_of(Array)))
        .and_return(
          begin
            account = Account.new(name: "Auto User", email: "auto-#{SecureRandom.hex(4)}@example.com")
            account.save!
            StandardId::PhoneNumberIdentifier.create!(account: account, value: phone, verified_at: Time.current)
            account
          end
        )

      account = strategy.send(:find_or_create_account!, phone)
      expect(account).to be_a(Account)

      identifier = StandardId::PhoneNumberIdentifier.find_by(value: phone)
      expect(identifier).to be_present
      expect(identifier.account).to eq(account)
      expect(identifier).to be_verified
    end
  end
end
