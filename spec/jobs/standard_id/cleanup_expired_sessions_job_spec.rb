require "rails_helper"

RSpec.describe StandardId::CleanupExpiredSessionsJob, type: :job do
  let(:account) { Account.create!(name: "Test", email: "cleanup-#{SecureRandom.hex(4)}@example.com") }

  describe "#perform" do
    it "deletes sessions that expired beyond the grace period" do
      old_session = StandardId::BrowserSession.create!(
        account: account,
        expires_at: 30.days.ago,
        ip_address: "127.0.0.1",
        user_agent: "Test"
      )

      described_class.new.perform(grace_period: 7.days)

      expect(StandardId::Session.exists?(old_session.id)).to be false
    end

    it "preserves sessions that expired within the grace period" do
      recent_session = StandardId::BrowserSession.create!(
        account: account,
        expires_at: 3.days.ago,
        ip_address: "127.0.0.1",
        user_agent: "Test"
      )

      described_class.new.perform(grace_period: 7.days)

      expect(StandardId::Session.exists?(recent_session.id)).to be true
    end

    it "preserves active sessions" do
      active_session = StandardId::BrowserSession.create!(
        account: account,
        expires_at: 1.day.from_now,
        ip_address: "127.0.0.1",
        user_agent: "Test"
      )

      described_class.new.perform(grace_period: 7.days)

      expect(StandardId::Session.exists?(active_session.id)).to be true
    end
  end
end
