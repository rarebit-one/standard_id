require "rails_helper"

RSpec.describe StandardId::Api::AuthenticationGuard, type: :model do
  let(:guard) { StandardId::Api::AuthenticationGuard.new }
  let(:api_session_manager) { instance_double(StandardId::Api::SessionManager) }
  let(:account) { Account.create!(name: "Test Service", email: "service@example.com") }

  describe "#require_session!" do
    context "when session is present and active" do
      let(:active_session) do
        StandardId::ServiceSession.create!(
          account: account,
          service_name: "test-service",
          service_version: "1.0.0",
          expires_at: 30.days.from_now
        )
      end

      it "returns the session without raising an error" do
        allow(api_session_manager).to receive(:load_current_session).and_return(active_session)

        result = guard.require_session!(api_session_manager)
        expect(result).to eq(active_session)
      end
    end

    context "when session is blank" do
      it "raises NotAuthenticatedError" do
        allow(api_session_manager).to receive(:load_current_session).and_return(nil)

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
          expires_at: 1.day.ago
        )
      end

      it "clears the session and raises ExpiredSessionError" do
        allow(api_session_manager).to receive(:load_current_session).and_return(expired_session)
        expect(api_session_manager).to receive(:clear_session!)

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
          expires_at: 30.days.from_now
        )
        session.revoke!
        session
      end

      it "clears the session and raises RevokedSessionError" do
        allow(api_session_manager).to receive(:load_current_session).and_return(revoked_session)
        expect(api_session_manager).to receive(:clear_session!)

        expect {
          guard.require_session!(api_session_manager)
        }.to raise_error(StandardId::RevokedSessionError, "Session has been revoked")
      end
    end
  end
end
