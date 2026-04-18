require "rails_helper"

RSpec.describe StandardId::CleanupExpiredAuthorizationCodesJob, type: :job do
  let(:account) { Account.create!(name: "Test", email: "cleanup-ac-#{SecureRandom.hex(4)}@example.com") }

  def create_code(attrs = {})
    StandardId::AuthorizationCode.create!({
      account: account,
      code_hash: Digest::SHA256.hexdigest(SecureRandom.uuid),
      client_id: "client-#{SecureRandom.hex(4)}",
      redirect_uri: "https://example.com/callback",
      issued_at: 1.hour.ago,
      expires_at: 10.minutes.from_now
    }.merge(attrs))
  end

  describe "#perform" do
    it "deletes codes that expired beyond the grace period" do
      old_code = create_code(expires_at: 30.days.ago)

      described_class.new.perform

      expect(StandardId::AuthorizationCode.exists?(old_code.id)).to be false
    end

    it "deletes codes that were consumed beyond the consumed grace period" do
      old_consumed = create_code(expires_at: 1.hour.ago, consumed_at: 30.days.ago)

      described_class.new.perform

      expect(StandardId::AuthorizationCode.exists?(old_consumed.id)).to be false
    end

    it "preserves codes that expired within the grace period" do
      recent_expired = create_code(expires_at: 3.days.ago)

      described_class.new.perform

      expect(StandardId::AuthorizationCode.exists?(recent_expired.id)).to be true
    end

    it "preserves codes consumed within the consumed grace period" do
      recent_consumed = create_code(expires_at: 1.hour.ago, consumed_at: 1.hour.ago)

      described_class.new.perform

      expect(StandardId::AuthorizationCode.exists?(recent_consumed.id)).to be true
    end

    it "preserves codes consumed within the consumed window even if expires_at is past the expired window" do
      # Regression for the expired-arm-of-OR bug: a code consumed 1 hour
      # ago (well inside the 1-day consumed window) but issued 30 days ago
      # (expires_at far past the 7-day expired window). The old query
      # deleted this row because the expired arm fired independently; the
      # fixed query scopes the expired arm to unconsumed rows.
      recently_consumed_old_code = create_code(
        expires_at: 30.days.ago,
        consumed_at: 1.hour.ago
      )

      described_class.new.perform

      expect(StandardId::AuthorizationCode.exists?(recently_consumed_old_code.id)).to be true
    end

    it "preserves active codes" do
      active_code = create_code(expires_at: 5.minutes.from_now)

      described_class.new.perform

      expect(StandardId::AuthorizationCode.exists?(active_code.id)).to be true
    end

    it "respects grace_period_seconds override" do
      two_day_expired = create_code(expires_at: 2.days.ago)

      described_class.new.perform(grace_period_seconds: 1.day.to_i)

      expect(StandardId::AuthorizationCode.exists?(two_day_expired.id)).to be false
    end

    it "respects consumed_grace_period_seconds override" do
      consumed_two_hours_ago = create_code(expires_at: 1.hour.ago, consumed_at: 2.hours.ago)

      described_class.new.perform(consumed_grace_period_seconds: 1.hour.to_i)

      expect(StandardId::AuthorizationCode.exists?(consumed_two_hours_ago.id)).to be false
    end

    it "logs the number of deleted records" do
      create_code(expires_at: 30.days.ago)
      create_code(expires_at: 30.days.ago)

      allow(Rails.logger).to receive(:info)

      described_class.new.perform

      expect(Rails.logger).to have_received(:info).with(/Cleaned up 2 authorization codes/)
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
