require "rails_helper"

RSpec.describe StandardId::CodeChallenge, type: :model do
  describe "validations" do
    it "validates presence and inclusion of realm" do
      challenge = described_class.new(
        realm: nil,
        channel: "email",
        target: "user@example.com",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:realm]).to be_present

      challenge.realm = "authentication"
      challenge.validate
      expect(challenge.errors[:realm]).to be_empty
    end

    it "validates presence and inclusion of channel" do
      challenge = described_class.new(
        realm: "authentication",
        channel: nil,
        target: "user@example.com",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:channel]).to be_present

      challenge.channel = "email"
      challenge.validate
      expect(challenge.errors[:channel]).to be_empty
    end

    it "validates presence of target" do
      challenge = described_class.new(
        realm: "authentication",
        channel: "email",
        target: nil,
        code: "123456",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:target]).to be_present
    end

    it "validates presence of code" do
      challenge = described_class.new(
        realm: "authentication",
        channel: "email",
        target: "user@example.com",
        code: nil,
        expires_at: 10.minutes.from_now
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:code]).to be_present
    end

    it "validates presence of expires_at" do
      challenge = described_class.new(
        realm: "authentication",
        channel: "email",
        target: "user@example.com",
        code: "123456",
        expires_at: nil
      )
      expect(challenge).not_to be_valid
      expect(challenge.errors[:expires_at]).to be_present
    end

    it "allows valid realms and channels" do
      challenge = described_class.new(
        realm: "authentication",
        channel: "sms",
        target: "+14155550123",
        code: "654321",
        expires_at: 10.minutes.from_now
      )
      expect(challenge).to be_valid
    end
  end

  describe "scopes" do
    let!(:active) do
      described_class.create!(
        realm: "authentication",
        channel: "email",
        target: "active@example.com",
        code: "111111",
        expires_at: 10.minutes.from_now
      )
    end

    let!(:expired) do
      described_class.create!(
        realm: "authentication",
        channel: "email",
        target: "expired@example.com",
        code: "222222",
        expires_at: 1.minute.ago
      )
    end

    let!(:used) do
      described_class.create!(
        realm: "authentication",
        channel: "email",
        target: "used@example.com",
        code: "333333",
        expires_at: 10.minutes.from_now,
        used_at: Time.current
      )
    end

    it ".active returns only active" do
      expect(described_class.active).to contain_exactly(active)
    end

    it ".expired returns only expired" do
      expect(described_class.expired).to contain_exactly(expired)
    end

    it ".used returns only used" do
      expect(described_class.used).to contain_exactly(used)
    end
  end

  describe "instance methods" do
    it "expired?/used?/active? reflect state" do
      ch = described_class.create!(
        realm: "authentication",
        channel: "email",
        target: "user@example.com",
        code: "123456",
        expires_at: 10.minutes.from_now
      )
      expect(ch).not_to be_expired
      expect(ch).not_to be_used
      expect(ch).to be_active

      ch.update!(expires_at: 1.minute.ago)
      expect(ch).to be_expired
      expect(ch).not_to be_active
    end

    it "use! sets used_at and deactivates the challenge" do
      ch = described_class.create!(
        realm: "authentication",
        channel: "sms",
        target: "+14155550123",
        code: "654321",
        expires_at: 10.minutes.from_now
      )
      expect(ch).to be_active
      ch.use!
      expect(ch).to be_used
      expect(ch).not_to be_active
    end
  end
end
