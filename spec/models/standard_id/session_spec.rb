require "rails_helper"

RSpec.describe StandardId::Session, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { Account.create!(name: "Test User", email: "test@example.com") }

  describe "associations" do
    it { should belong_to(:account) }
    it { should have_many(:refresh_tokens) }
  end

  describe "scopes" do
    let!(:active_session) do
      StandardId::BrowserSession.create!(
        account:,
        user_agent: "Chrome/91.0",
        expires_at: 1.hour.from_now,
        revoked_at: nil
      )
    end

    let!(:expired_session) do
      StandardId::BrowserSession.create!(
        account:,
        user_agent: "Chrome/91.0",
        expires_at: 1.hour.ago,
        revoked_at: nil
      )
    end

    let!(:revoked_session) do
      StandardId::BrowserSession.create!(
        account:,
        user_agent: "Chrome/91.0",
        expires_at: 1.hour.from_now,
        revoked_at: 1.minute.ago
      )
    end

    describe ".active" do
      it "returns only non-revoked, non-expired sessions" do
        expect(StandardId::Session.active).to contain_exactly(active_session)
      end
    end

    describe ".expired" do
      it "returns only expired sessions" do
        expect(StandardId::Session.expired).to contain_exactly(expired_session)
      end
    end

    describe ".revoked" do
      it "returns only revoked sessions" do
        expect(StandardId::Session.revoked).to contain_exactly(revoked_session)
      end
    end
  end

  describe "instance methods" do
    let(:session) do
      StandardId::BrowserSession.create!(
        account:,
        user_agent: "Chrome/91.0",
        expires_at: 1.hour.from_now,
        revoked_at: nil
      )
    end

    describe "#active?" do
      it "returns true for non-revoked, non-expired sessions" do
        expect(session.active?).to be true
      end

      it "returns false for expired sessions" do
        session.update!(expires_at: 1.hour.ago)
        expect(session.active?).to be false
      end

      it "returns false for revoked sessions" do
        session.update!(revoked_at: Time.current)
        expect(session.active?).to be false
      end
    end

    describe "#expired?" do
      it "returns false for non-expired sessions" do
        expect(session.expired?).to be false
      end

      it "returns true for expired sessions" do
        session.update!(expires_at: 1.hour.ago)
        expect(session.expired?).to be true
      end
    end

    describe "#revoked?" do
      it "returns false for non-revoked sessions" do
        expect(session.revoked?).to be false
      end

      it "returns true for revoked sessions" do
        session.update!(revoked_at: Time.current)
        expect(session.revoked?).to be true
      end
    end

    describe "before_destroy" do
      it "revokes active refresh tokens before session is destroyed" do
        active_rt = StandardId::RefreshToken.create!(
          account: account,
          session: session,
          token_digest: Digest::SHA256.hexdigest("destroy-active-rt"),
          expires_at: 30.days.from_now
        )

        session.destroy!

        expect(active_rt.reload.revoked?).to be true
        expect(active_rt.session_id).to be_nil
      end
    end

    describe "#revoke!" do
      it "sets revoked_at to current time" do
        travel_to Time.current do
          session.revoke!
          expect(session.revoked_at).to eq(Time.current)
        end
      end

      it "revokes all associated active refresh tokens" do
        active_rt = StandardId::RefreshToken.create!(
          account: account,
          session: session,
          token_digest: Digest::SHA256.hexdigest("active-rt"),
          expires_at: 30.days.from_now
        )

        already_revoked_rt = StandardId::RefreshToken.create!(
          account: account,
          session: session,
          token_digest: Digest::SHA256.hexdigest("revoked-rt"),
          expires_at: 30.days.from_now,
          revoked_at: 1.day.ago
        )

        session.revoke!

        expect(active_rt.reload.revoked?).to be true
        expect(already_revoked_rt.reload.revoked_at).to be_within(1.second).of(1.day.ago)
      end
    end
  end

  describe ".authenticate_by_token" do
    let(:account) { Account.create!(name: "Auth Token", email: "auth-token@example.com") }

    let!(:session) do
      StandardId::DeviceSession.create!(
        account: account,
        device_id: "device-#{SecureRandom.hex(4)}",
        device_agent: "MyApp/1.0",
        expires_at: 30.days.from_now
      )
    end

    let(:token) { session.token }

    it "returns the session for a correct token" do
      expect(StandardId::Session.authenticate_by_token(token)).to eq(session)
    end

    it "returns nil for a blank token" do
      expect(StandardId::Session.authenticate_by_token(nil)).to be_nil
      expect(StandardId::Session.authenticate_by_token("")).to be_nil
    end

    it "returns nil when no row matches the lookup hash" do
      expect(StandardId::Session.authenticate_by_token("no-such-token")).to be_nil
    end

    it "returns nil when the lookup hash matches but the digest does not" do
      # The lookup_hash is only an index key: a row found by it is a candidate,
      # never an authenticated session. Simulate a forged/rotated digest.
      session.update_column(:token_digest, BCrypt::Password.create("a-different-token"))

      expect(StandardId::Session.authenticate_by_token(token)).to be_nil
    end

    it "returns nil rather than raising on a malformed digest" do
      session.update_column(:token_digest, "not-a-bcrypt-hash")

      expect { StandardId::Session.authenticate_by_token(token) }.not_to raise_error
      expect(StandardId::Session.authenticate_by_token(token)).to be_nil
    end

    it "honours the current scope" do
      session.revoke!

      expect(StandardId::Session.authenticate_by_token(token)).to eq(session)
      expect(StandardId::Session.active.authenticate_by_token(token)).to be_nil
    end

    it "honours an STI/type scope" do
      expect(StandardId::Session.api_compatible.authenticate_by_token(token)).to eq(session)
      expect(StandardId::BrowserSession.authenticate_by_token(token)).to be_nil
    end

    it "uses a constant-time comparison of the digests" do
      allow(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original

      StandardId::Session.authenticate_by_token(token)

      expect(ActiveSupport::SecurityUtils).to have_received(:secure_compare)
    end
  end

  describe "#authenticate_token" do
    let(:account) { Account.create!(name: "Auth Token", email: "auth-token-inst@example.com") }

    let(:session) do
      StandardId::DeviceSession.create!(
        account: account,
        device_id: "device-#{SecureRandom.hex(4)}",
        device_agent: "MyApp/1.0",
        expires_at: 30.days.from_now
      )
    end

    it "is true for the issued token" do
      expect(session.authenticate_token(session.token)).to be(true)
    end

    it "is false for a wrong token" do
      expect(session.authenticate_token("wrong")).to be(false)
    end

    it "is false for a blank token" do
      expect(session.authenticate_token(nil)).to be(false)
    end

    it "is false when the digest is blank" do
      # The column is NOT NULL, so this is a defensive in-memory guard rather
      # than a state the DB can hold.
      token = session.token
      session.token_digest = nil

      expect(session.authenticate_token(token)).to be(false)
    end

    # The whole reason this change needs no migration and no token rotation:
    # rows digested under the old BCrypt default (and rows written by an app
    # that sets token_digest_cost) must keep authenticating unchanged.
    context "with a legacy BCrypt digest" do
      it "authenticates the issued token" do
        token = session.token
        session.update_column(:token_digest, BCrypt::Password.create(token, cost: BCrypt::Engine::MIN_COST))

        expect(session.reload.authenticate_token(token)).to be(true)
      end

      it "rejects a wrong token" do
        session.update_column(:token_digest, BCrypt::Password.create("a-different-token", cost: BCrypt::Engine::MIN_COST))

        expect(session.reload.authenticate_token(session.token)).to be(false)
      end

      it "is selected by the stored digest, not by the current config" do
        # Config says HMAC; the row says BCrypt. The row wins — otherwise a
        # config flip would strand every session issued before it.
        token = session.token
        session.update_column(:token_digest, BCrypt::Password.create(token, cost: BCrypt::Engine::MIN_COST))
        StandardId.config.session.token_digest_cost = nil

        expect(session.reload.authenticate_token(token)).to be(true)
      end
    end

    it "rejects an HMAC digest computed under a different secret" do
      # Guards the keying: the digest must not be a bare unkeyed hash of the
      # token, or anyone who could read a digest could forge one.
      token = session.token
      foreign = OpenSSL::HMAC.hexdigest(
        "SHA256", "not-the-app-secret", "#{described_class::DIGEST_PREFIX}#{token}"
      )
      session.update_column(:token_digest, foreign)

      expect(session.reload.authenticate_token(token)).to be(false)
    end
  end

  describe "#generate_token_digest" do
    let(:account) { Account.create!(name: "Digest Cost Test", email: "digest@example.com") }

    after { StandardId.config.session.token_digest_cost = nil }

    it "uses an HMAC digest when token_digest_cost is nil" do
      StandardId.config.session.token_digest_cost = nil

      session = StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Chrome/120.0",
        expires_at: 30.days.from_now
      )

      expect(session.token_digest).to eq(described_class.hmac_token_digest(session.token))
      expect(session.token_digest).not_to start_with("$2")
    end

    it "domain-separates the digest from the lookup_hash" do
      # Both derive from the same token and the same secret, so a construction
      # that let them coincide would turn the indexed lookup column into the
      # credential itself.
      session = StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Chrome/120.0",
        expires_at: 30.days.from_now
      )

      expect(session.token_digest).not_to eq(session.lookup_hash)
    end

    it "respects a configured cost when set" do
      StandardId.config.session.token_digest_cost = BCrypt::Engine::MIN_COST

      session = StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Chrome/120.0",
        expires_at: 30.days.from_now
      )

      expect(BCrypt::Password.new(session.token_digest).cost).to eq(BCrypt::Engine::MIN_COST)
    end

    it "clamps below-minimum costs to MIN_COST" do
      StandardId.config.session.token_digest_cost = 1

      session = StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Chrome/120.0",
        expires_at: 30.days.from_now
      )

      expect(BCrypt::Password.new(session.token_digest).cost).to eq(BCrypt::Engine::MIN_COST)
    end

    it "clamps above-maximum costs to MAX_COST" do
      # BCrypt's MAX_COST is 31; a `create` at that cost takes ~10 minutes,
      # so we stub create to capture the effective cost without hashing.
      StandardId.config.session.token_digest_cost = BCrypt::Engine::MAX_COST + 10

      captured_cost = nil
      allow(BCrypt::Password).to receive(:create).and_wrap_original do |original, token, **opts|
        captured_cost = opts[:cost]
        # Call through at MIN_COST so the create is fast enough for the spec.
        original.call(token, cost: BCrypt::Engine::MIN_COST)
      end

      StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Chrome/120.0",
        expires_at: 30.days.from_now
      )

      expect(captured_cost).to eq(BCrypt::Engine::MAX_COST)
    end
  end

  describe "bulk revocation" do
    let(:other_account) { Account.create!(name: "Other", email: "other@example.com") }

    def create_session(klass: StandardId::BrowserSession, owner: account, **attrs)
      klass.create!({
        account: owner,
        user_agent: "Chrome/120.0",
        expires_at: 30.days.from_now
      }.merge(attrs))
    end

    def create_refresh_token(session:, owner: account, **attrs)
      StandardId::RefreshToken.create!({
        account: owner,
        session: session,
        token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
        expires_at: 30.days.from_now
      }.merge(attrs))
    end

    describe ".revoke_all_for!" do
      it "revokes every unrevoked session for the account and returns counts" do
        one = create_session
        two = create_session
        already = create_session(revoked_at: 1.hour.ago)

        result = described_class.revoke_all_for!(account, reason: "password_reset")

        expect(result.sessions_revoked).to eq(2)
        expect(one.reload).to be_revoked
        expect(two.reload).to be_revoked
        expect(already.reload.revoked_at).to be_within(1.second).of(1.hour.ago)
      end

      it "cascades to the sessions' active refresh tokens" do
        session = create_session
        active = create_refresh_token(session: session)
        revoked = create_refresh_token(session: session, revoked_at: 1.hour.ago)
        unrelated = create_refresh_token(session: create_session(owner: other_account), owner: other_account)

        result = described_class.revoke_all_for!(account, reason: "logout")

        expect(result.refresh_tokens_revoked).to eq(1)
        expect(active.reload.revoked_at).to be_present
        expect(revoked.reload.revoked_at).to be_within(1.second).of(1.hour.ago)
        expect(unrelated.reload.revoked_at).to be_nil
      end

      it "leaves other accounts' sessions alone" do
        mine = create_session
        theirs = create_session(owner: other_account)

        described_class.revoke_all_for!(account, reason: "logout")

        expect(mine.reload).to be_revoked
        expect(theirs.reload).not_to be_revoked
      end

      it "accepts an account id as well as a record" do
        session = create_session

        result = described_class.revoke_all_for!(account.id, reason: "logout")

        expect(result.sessions_revoked).to eq(1)
        expect(session.reload).to be_revoked
      end

      it "returns zero counts and publishes nothing when there is nothing to revoke" do
        events = []
        subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) { |p| events << p }

        result = described_class.revoke_all_for!(account, reason: "logout")

        expect(result.sessions_revoked).to eq(0)
        expect(result.refresh_tokens_revoked).to eq(0)
        expect(events).to be_empty
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      it "honours the current scope, so a subclass revokes only its own type" do
        browser = create_session
        device = StandardId::DeviceSession.create!(
          account: account,
          device_id: "device-#{SecureRandom.hex(4)}",
          device_agent: "MyApp/1.0",
          expires_at: 30.days.from_now
        )

        result = StandardId::DeviceSession.revoke_all_for!(account, reason: "logout")

        expect(result.sessions_revoked).to eq(1)
        expect(device.reload).to be_revoked
        expect(browser.reload).not_to be_revoked
      end

      it "publishes one SESSION_REVOKED per session, not a single aggregate" do
        one = create_session
        two = create_session
        events = []
        subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) { |p| events << p }

        described_class.revoke_all_for!(account, reason: "password_reset")

        expect(events.size).to eq(2)
        expect(events.map { |p| p[:session].id }).to match_array([one.id, two.id])
        expect(events.map { |p| p[:reason] }.uniq).to eq(["password_reset"])
        expect(events.map { |p| p[:account].id }.uniq).to eq([account.id])
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      it "carries the committed revoked_at on the published session objects" do
        create_session
        captured = nil
        subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) { |p| captured = p[:session] }

        described_class.revoke_all_for!(account, reason: "logout")

        expect(captured.revoked_at).to be_present
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end
    end

    describe ".revoke_sessions!" do
      it "revokes the given collection and returns counts" do
        session = create_session
        create_refresh_token(session: session)
        untouched = create_session

        result = described_class.revoke_sessions!([session], account: account, reason: "logout")

        expect(result.sessions_revoked).to eq(1)
        expect(result.refresh_tokens_revoked).to eq(1)
        expect(untouched.reload).not_to be_revoked
      end

      it "falls back to sessions.first.account when no account is passed" do
        session = create_session
        captured = nil
        subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) { |p| captured = p[:account] }

        described_class.revoke_sessions!([session], reason: "logout")

        expect(captured.id).to eq(account.id)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      it "keeps revoking after a subscriber raises, so no session loses its event" do
        one = create_session
        two = create_session
        seen = []
        subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) do |payload|
          seen << payload[:session].id
          raise "subscriber exploded"
        end

        expect {
          described_class.revoke_sessions!([one, two], account: account, reason: "logout")
        }.not_to raise_error

        expect(seen).to match_array([one.id, two.id])
        expect(one.reload).to be_revoked
        expect(two.reload).to be_revoked
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      # StandardId.logger is a memoized `config.logger || Rails.logger`, so
      # whatever the FIRST reader in the process saw is what every later caller
      # gets — including a value that is not a logger. If logging in the rescue
      # can raise, the rescue's whole guarantee (a failing subscriber must not
      # short-circuit the loop) evaporates on the first bad log call.
      it "still revokes every session when the logger cannot log" do
        one = create_session
        two = create_session
        allow(StandardId).to receive(:logger).and_return("not-a-logger")
        subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) do
          raise "subscriber exploded"
        end

        expect {
          described_class.revoke_sessions!([one, two], account: account, reason: "logout")
        }.not_to raise_error

        expect(one.reload).to be_revoked
        expect(two.reload).to be_revoked
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end
    end
  end
end
