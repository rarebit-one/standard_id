require "rails_helper"

RSpec.describe StandardId::CleanupExpiredRefreshTokensJob, type: :job do
  let(:account) { Account.create!(name: "Test", email: "cleanup-rt-#{SecureRandom.hex(4)}@example.com") }

  def create_refresh_token(attrs = {})
    StandardId::RefreshToken.create!({
      account: account,
      token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      expires_at: 30.days.from_now
    }.merge(attrs))
  end

  describe "#perform" do
    it "deletes tokens that expired beyond the grace period" do
      old_token = create_refresh_token(expires_at: 30.days.ago)

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::RefreshToken.exists?(old_token.id)).to be false
    end

    it "deletes tokens that were revoked beyond the grace period" do
      old_revoked = create_refresh_token(revoked_at: 30.days.ago)

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::RefreshToken.exists?(old_revoked.id)).to be false
    end

    it "preserves tokens that expired within the grace period" do
      recent_token = create_refresh_token(expires_at: 3.days.ago)

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::RefreshToken.exists?(recent_token.id)).to be true
    end

    it "preserves active tokens" do
      active_token = create_refresh_token

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::RefreshToken.exists?(active_token.id)).to be true
    end
  end
end
