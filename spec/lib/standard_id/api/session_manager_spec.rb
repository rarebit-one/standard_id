require "rails_helper"

RSpec.describe StandardId::Api::SessionManager, type: :model do
  let(:request) { instance_double(ActionDispatch::Request, headers: {}, remote_ip: "127.0.0.1") }
  let(:api_token_manager) { instance_double(StandardId::Api::TokenManager) }
  let(:session_manager) { StandardId::Api::SessionManager.new(request, api_token_manager) }
  let(:account) { Account.create!(name: "Test Service", email: "service@example.com") }

  describe "#load_current_session" do
    context "when no token is present" do
      it "returns nil" do
        allow(api_token_manager).to receive(:extract_bearer_token).and_return(nil)

        result = session_manager.load_current_session
        expect(result).to be_nil
      end
    end

    context "when token is present but no session found" do
      it "returns nil" do
        allow(api_token_manager).to receive(:extract_bearer_token).and_return("invalid_token")
        allow(api_token_manager).to receive(:generate_lookup_hash).with("invalid_token").and_return("invalid_hash")

        result = session_manager.load_current_session
        expect(result).to be_nil
      end
    end

    context "when valid device session exists" do
      let(:device_session) do
        StandardId::DeviceSession.create!(
          account: account,
          device_id: "test-device",
          device_agent: "Test Agent",
          expires_at: 30.days.from_now
        )
      end

      it "returns the session and updates last_refreshed_at" do
        token = device_session.token
        lookup_hash = device_session.lookup_hash

        allow(api_token_manager).to receive(:extract_bearer_token).and_return(token)
        allow(api_token_manager).to receive(:generate_lookup_hash).with(token).and_return(lookup_hash)

        expect {
          result = session_manager.load_current_session
          expect(result).to eq(device_session)
        }.to change { device_session.reload.last_refreshed_at }
      end

      it "caches the session on subsequent calls" do
        token = device_session.token
        lookup_hash = device_session.lookup_hash

        allow(api_token_manager).to receive(:extract_bearer_token).and_return(token)
        allow(api_token_manager).to receive(:generate_lookup_hash).with(token).and_return(lookup_hash)

        # First call
        first_result = session_manager.load_current_session
        # Second call should return cached result without hitting the database
        second_result = session_manager.load_current_session

        expect(first_result).to eq(second_result)
        expect(first_result).to eq(device_session)
      end
    end

    context "when valid service session exists" do
      let(:service_session) do
        StandardId::ServiceSession.create!(
          account: account,
          service_name: "test-service",
          service_version: "1.0.0",
          expires_at: 90.days.from_now
        )
      end

      it "returns the session without updating timestamps" do
        token = service_session.token
        lookup_hash = service_session.lookup_hash

        allow(api_token_manager).to receive(:extract_bearer_token).and_return(token)
        allow(api_token_manager).to receive(:generate_lookup_hash).with(token).and_return(lookup_hash)

        original_updated_at = service_session.updated_at

        result = session_manager.load_current_session
        expect(result).to eq(service_session)
        expect(service_session.reload.updated_at).to eq(original_updated_at)
      end
    end

    context "when session is inactive" do
      let(:expired_session) do
        StandardId::ServiceSession.create!(
          account: account,
          service_name: "expired-service",
          service_version: "1.0.0",
          expires_at: 1.day.ago
        )
      end

      it "returns nil for expired session" do
        token = expired_session.token
        lookup_hash = expired_session.lookup_hash

        allow(api_token_manager).to receive(:extract_bearer_token).and_return(token)
        allow(api_token_manager).to receive(:generate_lookup_hash).with(token).and_return(lookup_hash)

        result = session_manager.load_current_session
        expect(result).to be_nil
      end
    end
  end

  describe "#current_account" do
    context "when session exists" do
      let(:service_session) do
        StandardId::ServiceSession.create!(
          account: account,
          service_name: "test-service",
          service_version: "1.0.0",
          expires_at: 90.days.from_now
        )
      end

      it "returns the account from the session" do
        token = service_session.token
        lookup_hash = service_session.lookup_hash

        allow(api_token_manager).to receive(:extract_bearer_token).and_return(token)
        allow(api_token_manager).to receive(:generate_lookup_hash).with(token).and_return(lookup_hash)

        result = session_manager.current_account
        expect(result).to eq(account)
      end
    end

    context "when no session exists" do
      it "returns nil" do
        allow(api_token_manager).to receive(:extract_bearer_token).and_return(nil)

        result = session_manager.current_account
        expect(result).to be_nil
      end
    end
  end

  describe "#revoke_current_session!" do
    context "when session exists" do
      let(:service_session) do
        StandardId::ServiceSession.create!(
          account: account,
          service_name: "test-service",
          service_version: "1.0.0",
          expires_at: 90.days.from_now
        )
      end

      it "revokes the session and clears the cache" do
        token = service_session.token
        lookup_hash = service_session.lookup_hash

        allow(api_token_manager).to receive(:extract_bearer_token).and_return(token)
        allow(api_token_manager).to receive(:generate_lookup_hash).with(token).and_return(lookup_hash)

        # Load the session first
        session_manager.load_current_session

        # Revoke it
        session_manager.revoke_current_session!

        expect(service_session.reload.revoked?).to be true
        # Session should be cleared from cache
        expect(session_manager.instance_variable_get(:@current_session)).to be_nil
      end
    end

    context "when no session exists" do
      it "does nothing" do
        expect { session_manager.revoke_current_session! }.not_to raise_error
      end
    end
  end

  describe "#clear_session!" do
    it "clears the cached session" do
      session_manager.instance_variable_set(:@current_session, "some_session")

      session_manager.clear_session!

      expect(session_manager.instance_variable_get(:@current_session)).to be_nil
    end
  end
end
