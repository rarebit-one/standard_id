require "rails_helper"

RSpec.describe StandardId::Api::AuthenticationGuard, type: :model do
  let(:guard) { StandardId::Api::AuthenticationGuard.new }
  let(:api_session_manager) { instance_double(StandardId::Api::SessionManager) }
  let(:account) { Account.create!(name: "Test Service", email: "service@example.com") }
  let(:jwt_session) do
    StandardId::JwtService.session_class.new(
      account_id: account.id,
      client_id: SecureRandom.uuid,
      scopes: %w[openid read:users],
      grant_type: "client_credentials"
    )
  end

  describe "#require_session!" do
    context "when session is present and active" do
      let(:active_session) do
        StandardId::ServiceSession.create!(
          account: account,
          service_name: "test-service",
          service_version: "1.0.0",
          owner: account,
          expires_at: 30.days.from_now
        )
      end

      it "returns the session without raising an error" do
        allow(api_session_manager).to receive(:current_session).and_return(active_session)

        result = guard.require_session!(api_session_manager)
        expect(result).to eq(active_session)
      end
    end

    context "when session is blank" do
      it "raises NotAuthenticatedError" do
        allow(api_session_manager).to receive(:current_session).and_return(nil)

        expect {
          guard.require_session!(api_session_manager)
        }.to raise_error(StandardId::NotAuthenticatedError, "Invalid or missing access token")
      end
    end

    context "when session is expired" do
      let(:expired_session) do
        StandardId::ServiceSession.create!(
          account: account,
          service_name: "expired-service",
          service_version: "1.0.0",
          owner: account,
          expires_at: 1.day.ago
        )
      end

      it "clears the session and raises ExpiredSessionError" do
        allow(api_session_manager).to receive(:current_session).and_return(expired_session)
        allow(api_session_manager).to receive(:clear_session!)

        expect {
          guard.require_session!(api_session_manager)
        }.to raise_error(StandardId::ExpiredSessionError, "Session has expired")
      end
    end

    context "when session is revoked" do
      let(:revoked_session) do
        session = StandardId::ServiceSession.create!(
          account: account,
          service_name: "revoked-service",
          service_version: "1.0.0",
          owner: account,
          expires_at: 30.days.from_now
        )
        session.revoke!
        session
      end

      it "clears the session and raises RevokedSessionError" do
        allow(api_session_manager).to receive(:current_session).and_return(revoked_session)
        allow(api_session_manager).to receive(:clear_session!)

        expect {
          guard.require_session!(api_session_manager)
        }.to raise_error(StandardId::RevokedSessionError, "Session has been revoked")
      end
    end
  end

  describe "#require_scopes!" do
    before do
      allow(api_session_manager).to receive(:current_session).and_return(jwt_session)
    end

    it "returns the session when all required scopes are present" do
      expect(
        guard.require_scopes!(api_session_manager, "openid")
      ).to eq(jwt_session)
    end

    it "accepts an array of scopes and succeeds when any matches" do
      expect(
        guard.require_scopes!(api_session_manager, %w[openid read:users])
      ).to eq(jwt_session)
    end

    it "accepts symbol scopes" do
      expect(
        guard.require_scopes!(api_session_manager, :openid)
      ).to eq(jwt_session)
    end

    it "raises InvalidScopeError when none of the provided scopes match" do
      expect {
        guard.require_scopes!(api_session_manager, %w[admin:users write:users])
      }.to raise_error(StandardId::InvalidScopeError, /admin:users/)
    end
  end

  describe "event account resolution" do
    # The guard emits SESSION_VALIDATED / SESSION_EXPIRED events with an
    # `account:` payload. Previously each emission did its own account
    # lookup (find_by by account_id), which for two events per request
    # meant two duplicate queries in addition to the session_manager's
    # already-memoized current_account. The guard now prefers
    # session_manager.current_account when available.
    let(:active_session) do
      StandardId::ServiceSession.create!(
        account: account,
        service_name: "validated-service",
        service_version: "1.0.0",
        owner: account,
        expires_at: 30.days.from_now
      )
    end

    it "uses session_manager.current_account for the event payload and does not hit the DB on its own" do
      allow(api_session_manager).to receive(:current_session).and_return(active_session)
      allow(api_session_manager).to receive(:current_account).and_return(account)

      received_payload = nil
      subscription = StandardId::Events.subscribe(StandardId::Events::SESSION_VALIDATED) do |payload|
        received_payload = payload
      end

      # Assert account_class.find_by is NOT called — the guard should delegate
      # to the session_manager's memoized current_account.
      expect(StandardId.account_class).not_to receive(:find_by)

      guard.require_session!(api_session_manager)

      expect(received_payload).to be_present
      expect(received_payload[:account]).to eq(account)
    ensure
      StandardId::Events.unsubscribe(subscription) if subscription
    end
  end
end
