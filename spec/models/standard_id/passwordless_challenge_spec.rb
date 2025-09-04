require "rails_helper"

RSpec.describe StandardId::PasswordlessChallenge, type: :model do
  describe "validations" do
    it "validates presence of connection_type" do
      challenge = StandardId::PasswordlessChallenge.new(
        username: "test@example.com",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:connection_type]).to include("can't be blank")
    end

    it "validates presence of username" do
      challenge = StandardId::PasswordlessChallenge.new(
        connection_type: "email",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:username]).to include("can't be blank")
    end

    it "validates presence of code" do
      challenge = StandardId::PasswordlessChallenge.new(
        connection_type: "email",
        username: "test@example.com",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:code]).to include("can't be blank")
    end

    it "validates presence of expires_at" do
      challenge = StandardId::PasswordlessChallenge.new(
        connection_type: "email",
        username: "test@example.com",
        code: "123456"
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:expires_at]).to include("can't be blank")
    end

    it "validates connection_type inclusion" do
      challenge = StandardId::PasswordlessChallenge.new(
        connection_type: "invalid",
        username: "test@example.com",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:connection_type]).to include("is not included in the list")
    end

    it "allows valid connection types" do
      %w[email sms].each do |connection_type|
        challenge = StandardId::PasswordlessChallenge.new(
          connection_type: connection_type,
          username: "test@example.com",
          code: "123456",
          expires_at: 10.minutes.from_now
        )
        expect(challenge).to be_valid
      end
    end
  end

  describe "scopes" do
    let!(:active_challenge) do
      StandardId::PasswordlessChallenge.create!(
        connection_type: "email",
        username: "active@example.com",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
    end

    let!(:expired_challenge) do
      StandardId::PasswordlessChallenge.create!(
        connection_type: "email",
        username: "expired@example.com",
        code: "654321",
        expires_at: 1.minute.ago
      )
    end

    let!(:used_challenge) do
      StandardId::PasswordlessChallenge.create!(
        connection_type: "email",
        username: "used@example.com",
        code: "789012",
        expires_at: 10.minutes.from_now,
        used_at: 1.minute.ago
      )
    end

    describe ".active" do
      it "returns only active challenges" do
        expect(StandardId::PasswordlessChallenge.active).to contain_exactly(active_challenge)
      end
    end

    describe ".expired" do
      it "returns only expired challenges" do
        expect(StandardId::PasswordlessChallenge.expired).to contain_exactly(expired_challenge)
      end
    end

    describe ".used" do
      it "returns only used challenges" do
        expect(StandardId::PasswordlessChallenge.used).to contain_exactly(used_challenge)
      end
    end
  end

  describe "instance methods" do
    let(:challenge) do
      StandardId::PasswordlessChallenge.new(
        connection_type: "email",
        username: "test@example.com",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
    end

    describe "#expired?" do
      it "returns false for future expiry" do
        challenge.expires_at = 10.minutes.from_now
        expect(challenge.expired?).to be false
      end

      it "returns true for past expiry" do
        challenge.expires_at = 1.minute.ago
        expect(challenge.expired?).to be true
      end
    end

    describe "#used?" do
      it "returns false when used_at is nil" do
        challenge.used_at = nil
        expect(challenge.used?).to be false
      end

      it "returns true when used_at is present" do
        challenge.used_at = 1.minute.ago
        expect(challenge.used?).to be true
      end
    end

    describe "#active?" do
      it "returns true when not expired and not used" do
        challenge.expires_at = 10.minutes.from_now
        challenge.used_at = nil
        expect(challenge.active?).to be true
      end

      it "returns false when expired" do
        challenge.expires_at = 1.minute.ago
        challenge.used_at = nil
        expect(challenge.active?).to be false
      end

      it "returns false when used" do
        challenge.expires_at = 10.minutes.from_now
        challenge.used_at = 1.minute.ago
        expect(challenge.active?).to be false
      end
    end

    describe "#use!" do
      it "sets used_at to current time" do
        challenge.save!
        expect { challenge.use! }.to change { challenge.used_at }.from(nil)
        expect(challenge.used_at).to be_within(1.second).of(Time.current)
      end
    end
  end
end
