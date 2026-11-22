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

  describe "code storage" do
    let(:old_secret) { "old-secret-key-base-#{SecureRandom.hex(8)}" }

    def create_challenge(code: "123456")
      described_class.create!(
        realm: "authentication", channel: "email", target: "digest@example.com",
        code: code, expires_at: 10.minutes.from_now
      )
    end

    it "stores an HMAC of the code, never the code" do
      challenge = create_challenge

      row = described_class.connection.select_one(
        described_class.where(id: challenge.id).select(:code, :code_digest).to_sql
      )
      expect(row["code"]).to be_nil
      expect(row["code_digest"]).to eq(described_class.digest_code("123456"))
      expect(row["code_digest"]).not_to eq(Digest::SHA256.hexdigest("123456"))
    end

    it "keeps the raw code on the created instance only" do
      challenge = create_challenge

      expect(challenge.code).to eq("123456")
      expect(described_class.find(challenge.id).code).to be_nil
    end

    it "matches the right code and rejects a wrong or blank one" do
      challenge = described_class.find(create_challenge.id)

      expect(challenge.code_matches?("123456")).to be(true)
      expect(challenge.code_matches?("654321")).to be(false)
      expect(challenge.code_matches?("")).to be(false)
      expect(challenge.code_matches?(nil)).to be(false)
    end

    it "can be used and have attempts recorded once read back without its code" do
      challenge = described_class.find(create_challenge.id)

      expect { challenge.update!(metadata: { "attempts" => 1 }) }.not_to raise_error
      expect { challenge.use! }.not_to raise_error
    end

    # Challenges issued before migration 20261122000000 carry only the
    # plaintext column; they must keep verifying until they expire.
    context "with a legacy plaintext row" do
      let(:legacy) do
        challenge = create_challenge
        challenge.update_columns(code: "246810", code_digest: nil)
        described_class.find(challenge.id)
      end

      it "verifies against the plaintext column" do
        expect(legacy.code_matches?("246810")).to be(true)
        expect(legacy.code_matches?("123456")).to be(false)
      end

      it "still reports the legacy code" do
        expect(legacy.code).to eq("246810")
      end
    end

    context "with a digest written under a previous secret_key_base" do
      let(:challenge) do
        record = create_challenge
        record.update_column(:code_digest, described_class.digest_code("123456", secret: old_secret))
        described_class.find(record.id)
      end

      it "is rejected by default" do
        expect(challenge.code_matches?("123456")).to be(false)
      end

      it "is accepted once the old secret is listed" do
        StandardId.config.previous_secret_key_bases = [old_secret]

        expect(challenge.code_matches?("123456")).to be(true)
        expect(challenge.code_matches?("654321")).to be(false)
      end
    end

    it "writes under the current secret even when previous secrets are listed" do
      StandardId.config.previous_secret_key_bases = [old_secret]

      expect(create_challenge.code_digest).to eq(described_class.digest_code("123456", secret: Rails.configuration.secret_key_base))
    end

    it "leaves the code and its digest out of serialisation" do
      challenge = create_challenge

      expect(challenge.as_json.keys).not_to include("code", "code_digest")
      expect(challenge.as_json(except: [:metadata]).keys).not_to include("code", "code_digest", "metadata")
      expect(challenge.to_json).not_to include("123456")
    end

    context "before the digest migration has run" do
      before { allow(described_class).to receive(:code_digest_column?).and_return(false) }

      it "writes the plaintext column, as before" do
        challenge = described_class.new(code: "135790")

        expect(challenge.read_attribute(:code)).to eq("135790")
        expect(challenge.code_digest).to be_nil
      end
    end
  end
end
