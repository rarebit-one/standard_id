require "rails_helper"

RSpec.describe StandardId::RefreshToken, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { Account.create!(name: "Test User", email: "test@example.com") }

  def create_refresh_token(attrs = {})
    StandardId::RefreshToken.create!({
      account: account,
      token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      expires_at: 30.days.from_now
    }.merge(attrs))
  end

  describe "associations" do
    it { should belong_to(:account) }
    it { should belong_to(:session).optional }
    it { should belong_to(:previous_token).optional }
  end

  describe "validations" do
    it { should validate_presence_of(:token_digest) }
    it { should validate_presence_of(:expires_at) }

    it "validates uniqueness of token_digest" do
      create_refresh_token(token_digest: "unique-digest")
      duplicate = StandardId::RefreshToken.new(
        account: account,
        token_digest: "unique-digest",
        expires_at: 30.days.from_now
      )
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:token_digest]).to include("has already been taken")
    end
  end

  describe "scopes" do
    let!(:active_token) { create_refresh_token }
    let!(:expired_token) { create_refresh_token(expires_at: 1.hour.ago) }
    let!(:revoked_token) { create_refresh_token(revoked_at: 1.minute.ago) }

    describe ".active" do
      it "returns only non-revoked, non-expired tokens" do
        expect(StandardId::RefreshToken.active).to contain_exactly(active_token)
      end
    end

    describe ".expired" do
      it "returns only expired tokens" do
        expect(StandardId::RefreshToken.expired).to contain_exactly(expired_token)
      end
    end

    describe ".revoked" do
      it "returns only revoked tokens" do
        expect(StandardId::RefreshToken.revoked).to contain_exactly(revoked_token)
      end
    end
  end

  describe ".digest_for" do
    it "returns a SHA256 hex digest of the jti" do
      jti = "test-jti-value"
      expected = Digest::SHA256.hexdigest(jti)
      expect(StandardId::RefreshToken.digest_for(jti)).to eq(expected)
    end
  end

  describe ".find_by_jti" do
    it "finds a token by its jti" do
      jti = SecureRandom.uuid
      token = create_refresh_token(token_digest: StandardId::RefreshToken.digest_for(jti))
      expect(StandardId::RefreshToken.find_by_jti(jti)).to eq(token)
    end

    it "returns nil when no matching token exists" do
      expect(StandardId::RefreshToken.find_by_jti("nonexistent")).to be_nil
    end
  end

  describe "instance methods" do
    describe "#active?" do
      it "returns true for non-revoked, non-expired tokens" do
        token = create_refresh_token
        expect(token.active?).to be true
      end

      it "returns false for expired tokens" do
        token = create_refresh_token(expires_at: 1.hour.ago)
        expect(token.active?).to be false
      end

      it "returns false for revoked tokens" do
        token = create_refresh_token(revoked_at: Time.current)
        expect(token.active?).to be false
      end
    end

    describe "#revoke!" do
      it "sets revoked_at to current time" do
        token = create_refresh_token
        travel_to Time.current do
          token.revoke!
          expect(token.revoked_at).to eq(Time.current)
        end
      end

      it "does not update if already revoked" do
        original_time = 1.hour.ago
        token = create_refresh_token(revoked_at: original_time)
        token.revoke!
        expect(token.reload.revoked_at).to be_within(1.second).of(original_time)
      end
    end

    describe "#revoke_family!" do
      it "revokes all tokens in the family chain" do
        root = create_refresh_token
        child = create_refresh_token(previous_token: root)
        grandchild = create_refresh_token(previous_token: child)

        grandchild.revoke_family!

        [root, child, grandchild].each do |t|
          expect(t.reload.revoked?).to be true
        end
      end

      it "revokes tokens in a family when called from middle of chain" do
        root = create_refresh_token
        child = create_refresh_token(previous_token: root)
        grandchild = create_refresh_token(previous_token: child)

        child.revoke_family!

        [root, child, grandchild].each do |t|
          expect(t.reload.revoked?).to be true
        end
      end

      it "does not revoke tokens in other families" do
        root1 = create_refresh_token
        child1 = create_refresh_token(previous_token: root1)

        other_root = create_refresh_token
        other_child = create_refresh_token(previous_token: other_root)

        child1.revoke_family!

        expect(root1.reload.revoked?).to be true
        expect(child1.reload.revoked?).to be true
        expect(other_root.reload.revoked?).to be false
        expect(other_child.reload.revoked?).to be false
      end
    end
  end
end
