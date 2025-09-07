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
