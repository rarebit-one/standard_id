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

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::Session.exists?(old_session.id)).to be false
    end

    it "preserves sessions that expired within the grace period" do
      recent_session = StandardId::BrowserSession.create!(
        account: account,
        expires_at: 3.days.ago,
        ip_address: "127.0.0.1",
        user_agent: "Test"
      )

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::Session.exists?(recent_session.id)).to be true
    end

    it "preserves active sessions" do
      active_session = StandardId::BrowserSession.create!(
        account: account,
        expires_at: 1.day.from_now,
        ip_address: "127.0.0.1",
        user_agent: "Test"
      )

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::Session.exists?(active_session.id)).to be true
    end
  end

  # SIDEKICK-WEB-3K: `delete_all` skips `dependent:`, and standard_id_refresh_tokens.session_id
  # is a foreign key to standard_id_sessions (ON DELETE NO ACTION in the gem's migration), so
  # an expired session that still had refresh tokens failed the whole job on every run.
  describe "sessions referenced by refresh tokens" do
    def session_expired(ago)
      StandardId::DeviceSession.create!(account: account, expires_at: ago.ago, device_id: "dev-#{SecureRandom.hex(4)}", device_agent: "RSpec",
                                        ip_address: "127.0.0.1", user_agent: "Test")
    end

    def refresh_token_for(session, expires_at:, revoked_at: nil)
      StandardId::RefreshToken.create!(
        account: account, session: session, expires_at: expires_at, revoked_at: revoked_at,
        token_digest: Digest::SHA256.hexdigest(SecureRandom.hex(8))
      )
    end

    it "deletes an expired session whose refresh tokens are all dead, detaching them instead of failing" do
      session = session_expired(30.days)
      expired_rt = refresh_token_for(session, expires_at: 20.days.ago)
      revoked_rt = refresh_token_for(session, expires_at: 10.days.from_now, revoked_at: 1.day.ago)

      expect { described_class.new.perform(grace_period_seconds: 7.days.to_i) }.not_to raise_error

      expect(StandardId::Session.exists?(session.id)).to be(false)
      # Dead tokens stay for reuse detection until CleanupExpiredRefreshTokensJob's own window.
      expect(expired_rt.reload.session_id).to be_nil
      expect(revoked_rt.reload.session_id).to be_nil
      expect(revoked_rt.revoked_at).to be_within(1.second).of(1.day.ago)
    end

    # Refresh tokens deliberately outlive their session's expiry (RefreshTokenFlow
    # #validate_parent_session! checks revocation, not expiry — jumpdrive runs a
    # 1-day browser session against 30-day refresh tokens). Deleting or detaching
    # the session would drop the "revoke this session ends access" linkage.
    it "keeps an expired session that still has a live refresh token, and leaves the token alone" do
      session = session_expired(30.days)
      live_rt = refresh_token_for(session, expires_at: 20.days.from_now)

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::Session.exists?(session.id)).to be(true)
      expect(live_rt.reload.session_id).to eq(session.id)
      expect(live_rt).to be_active
    end

    # A session-less live token (client_credentials / M2M) must not reach the
    # "has a live token" subquery: a NULL inside NOT IN makes the predicate
    # unknown for every row, which would silently stop all cleanup.
    it "is not blocked by live refresh tokens that have no session" do
      StandardId::RefreshToken.create!(account: account, session: nil, expires_at: 20.days.from_now,
                                       token_digest: Digest::SHA256.hexdigest(SecureRandom.hex(8)))
      session = session_expired(30.days)

      described_class.new.perform(grace_period_seconds: 7.days.to_i)

      expect(StandardId::Session.exists?(session.id)).to be(false)
    end

    it "cleans up in batches, each in its own transaction" do
      sessions = Array.new(5) { session_expired(30.days) }
      sessions.each { |s| refresh_token_for(s, expires_at: 20.days.ago) }
      keep = session_expired(30.days)
      refresh_token_for(keep, expires_at: 20.days.from_now)
      allow(StandardId::Session).to receive(:transaction).and_call_original

      described_class.new.perform(grace_period_seconds: 7.days.to_i, batch_size: 2)

      expect(StandardId::Session.where(id: sessions.map(&:id))).to be_empty
      expect(StandardId::Session.exists?(keep.id)).to be(true)
      expect(StandardId::Session).to have_received(:transaction).exactly(3).times
    end
  end
end
