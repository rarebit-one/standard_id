require "rails_helper"

RSpec.describe StandardId::CleanupExpiredCodeChallengesJob, type: :job do
  let(:account) { Account.create!(name: "Test", email: "cleanup-cc-#{SecureRandom.hex(4)}@example.com") }

  def create_challenge(attrs = {})
    StandardId::CodeChallenge.create!({
      realm: "authentication",
      channel: "email",
      target: "user-#{SecureRandom.hex(4)}@example.com",
      code: SecureRandom.hex(3),
      expires_at: 10.minutes.from_now
    }.merge(attrs))
  end

  describe "#perform" do
    it "deletes challenges that expired beyond the grace period" do
      old_challenge = create_challenge(expires_at: 30.days.ago)

      described_class.new.perform

      expect(StandardId::CodeChallenge.exists?(old_challenge.id)).to be false
    end

    it "deletes challenges that were used beyond the used grace period" do
      old_used = create_challenge(expires_at: 1.hour.ago, used_at: 30.days.ago)

      described_class.new.perform

      expect(StandardId::CodeChallenge.exists?(old_used.id)).to be false
    end

    it "preserves challenges that expired within the grace period" do
      recent_expired = create_challenge(expires_at: 3.days.ago)

      described_class.new.perform

      expect(StandardId::CodeChallenge.exists?(recent_expired.id)).to be true
    end

    it "preserves challenges used within the used grace period" do
      recent_used = create_challenge(expires_at: 1.hour.ago, used_at: 1.hour.ago)

      described_class.new.perform

      expect(StandardId::CodeChallenge.exists?(recent_used.id)).to be true
    end

    it "preserves challenges used within the used window even if expires_at is past the expired window" do
      # Regression for the expired-arm-of-OR bug: a challenge used 1 hour
      # ago (inside the 1-day used window) but with expires_at set 30
      # days ago (past the 7-day expired window). The old query deleted
      # this row because the expired arm fired independently; the fixed
      # query scopes the expired arm to rows where used_at IS NULL.
      recently_used_old_challenge = create_challenge(
        expires_at: 30.days.ago,
        used_at: 1.hour.ago
      )

      described_class.new.perform

      expect(StandardId::CodeChallenge.exists?(recently_used_old_challenge.id)).to be true
    end

    it "preserves active challenges" do
      active_challenge = create_challenge(expires_at: 5.minutes.from_now)

      described_class.new.perform

      expect(StandardId::CodeChallenge.exists?(active_challenge.id)).to be true
    end

    it "respects grace_period_seconds override" do
      two_day_expired = create_challenge(expires_at: 2.days.ago)

      described_class.new.perform(grace_period_seconds: 1.day.to_i)

      expect(StandardId::CodeChallenge.exists?(two_day_expired.id)).to be false
    end

    it "respects used_grace_period_seconds override" do
      used_two_hours_ago = create_challenge(expires_at: 1.hour.ago, used_at: 2.hours.ago)

      described_class.new.perform(used_grace_period_seconds: 1.hour.to_i)

      expect(StandardId::CodeChallenge.exists?(used_two_hours_ago.id)).to be false
    end

    it "logs the number of deleted records" do
      create_challenge(expires_at: 30.days.ago)
      create_challenge(expires_at: 30.days.ago)

      allow(Rails.logger).to receive(:info)

      described_class.new.perform

      expect(Rails.logger).to have_received(:info).with(/Cleaned up 2 code challenges/)
    end

    it "does not touch unrelated tables" do
      session = StandardId::BrowserSession.create!(
        account: account,
        expires_at: 30.days.ago,
        ip_address: "127.0.0.1",
        user_agent: "Test"
      )
      refresh_token = StandardId::RefreshToken.create!(
        account: account,
        token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
        expires_at: 30.days.ago
      )

      described_class.new.perform

      expect(StandardId::Session.exists?(session.id)).to be true
      expect(StandardId::RefreshToken.exists?(refresh_token.id)).to be true
    end
  end
end
