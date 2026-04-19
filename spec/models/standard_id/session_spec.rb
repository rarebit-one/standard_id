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

  describe "#generate_token_digest" do
    let(:account) { Account.create!(name: "Digest Cost Test", email: "digest@example.com") }

    after { StandardId.config.session.token_digest_cost = nil }

    it "uses BCrypt's built-in default when token_digest_cost is nil" do
      StandardId.config.session.token_digest_cost = nil

      # Reference cost for BCrypt's built-in default in the current env.
      # In test env BCrypt sets this to MIN_COST for speed; in prod it's 12.
      reference_cost = BCrypt::Password.create("probe").cost

      session = StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Chrome/120.0",
        expires_at: 30.days.from_now
      )

      expect(BCrypt::Password.new(session.token_digest).cost).to eq(reference_cost)
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
end
