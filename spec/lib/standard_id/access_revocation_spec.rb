require "rails_helper"

RSpec.describe StandardId::AccessRevocation do
  let(:account) { Account.create!(name: "Revoked", email: "revoked@example.com") }

  def create_session(created_at: Time.current)
    StandardId::BrowserSession.create!(account: account, user_agent: "RSpec", expires_at: 1.day.from_now).tap do |session|
      session.update_columns(created_at: created_at)
    end
  end

  def create_refresh_token(session: nil, created_at: Time.current)
    StandardId::RefreshToken.create!(
      account: account, session: session, token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid), expires_at: 30.days.from_now
    ).tap { |token| token.update_columns(created_at: created_at) }
  end

  def capture_revocations
    events = []
    subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) { |payload| events << payload }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  describe ".revoke_all!" do
    it "revokes every session and every refresh token, including those with no session" do
      session = create_session
      under_session = create_refresh_token(session: session)
      sessionless = create_refresh_token

      described_class.revoke_all!(account, reason: "password_reset")

      expect(session.reload).to be_revoked
      expect([under_session, sessionless].map { |token| token.reload.revoked_at }).to all(be_present)
    end

    it "publishes one SESSION_REVOKED per session, each with its own session" do
      one = create_session
      two = create_session

      events = capture_revocations { described_class.revoke_all!(account, reason: "password_reset") }

      expect(events.map { |e| e[:session].id }).to contain_exactly(one.id, two.id)
      expect(events.map { |e| e[:reason] }.uniq).to eq(["password_reset"])
    end

    it "leaves other accounts alone" do
      other = Account.create!(name: "Other", email: "other@example.com")
      other_token = StandardId::RefreshToken.create!(account: other, token_digest: Digest::SHA256.hexdigest("other"), expires_at: 30.days.from_now)

      described_class.revoke_all!(account, reason: "password_reset")

      expect(other_token.reload.revoked_at).to be_nil
    end

    context "with issued_before" do
      it "spares sessions and refresh tokens created at or after it" do
        cutoff = 1.minute.ago
        old_session = create_session(created_at: 1.hour.ago)
        new_session = create_session
        old_token = create_refresh_token(created_at: 1.hour.ago)
        new_token = create_refresh_token

        described_class.revoke_all!(account, reason: "pending_signup_discarded", issued_before: cutoff)

        expect(old_session.reload).to be_revoked
        expect(new_session.reload).not_to be_revoked
        expect(old_token.reload.revoked_at).to be_present
        expect(new_token.reload.revoked_at).to be_nil
      end
    end

    it "rolls back with the caller's transaction" do
      session = create_session

      ActiveRecord::Base.transaction do
        described_class.revoke_all!(account, reason: "password_reset")
        raise ActiveRecord::Rollback
      end

      expect(session.reload).not_to be_revoked
    end
  end
end
