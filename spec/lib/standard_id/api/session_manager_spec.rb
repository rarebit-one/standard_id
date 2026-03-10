require "rails_helper"
require "ostruct"

RSpec.describe StandardId::Api::SessionManager, type: :model do
  let(:request) { instance_double(ActionDispatch::Request, headers: {}, remote_ip: "127.0.0.1") }
  let(:api_token_manager) { instance_double(StandardId::Api::TokenManager) }
  let(:session_manager) { StandardId::Api::SessionManager.new(api_token_manager, request: request) }
  let(:account) { Account.create!(name: "Test Service", email: "service@example.com") }

  describe "#current_session" do
    context "when no token is present" do
      it "returns nil" do
        allow(api_token_manager).to receive(:bearer_token).and_return(nil)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(nil)

        result = session_manager.current_session
        expect(result).to be_nil
      end
    end

    context "when token is present but no session found" do
      it "returns nil" do
        allow(api_token_manager).to receive(:bearer_token).and_return("invalid_token")
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(nil)

        result = session_manager.current_session
        expect(result).to be_nil
      end
    end

    context "when valid JWT access token exists" do
      let(:token) { "jwt-token" }
      let(:jwt_session) { OpenStruct.new(account_id: account.id, client_id: "dev-1", scopes: [], grant_type: "access_token", active?: true) }

      it "returns the decoded jwt session" do
        allow(api_token_manager).to receive(:bearer_token).and_return(token)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(jwt_session)

        result = session_manager.current_session
        expect(result).to eq(jwt_session)
      end

      it "caches the session on subsequent calls" do
        allow(api_token_manager).to receive(:bearer_token).and_return(token)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(jwt_session)

        first_result = session_manager.current_session
        second_result = session_manager.current_session
        expect(second_result).to equal(first_result)
      end
    end

    context "when valid service jwt exists" do
      let(:token) { "jwt-token" }
      let(:jwt_session) { OpenStruct.new(account_id: account.id, client_id: "svc-1", scopes: ["service:read"], grant_type: "access_token", active?: true) }

      it "returns the session-like jwt object" do
        allow(api_token_manager).to receive(:bearer_token).and_return(token)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(jwt_session)

        result = session_manager.current_session
        expect(result).to eq(jwt_session)
      end
    end

    context "when session is inactive" do
      it "returns nil for inactive jwt session" do
        token = "jwt-token"
        inactive_jwt = OpenStruct.new(account_id: account.id, active?: false)
        allow(api_token_manager).to receive(:bearer_token).and_return(token)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(inactive_jwt)

        result = session_manager.current_session
        expect(result).to be_nil
      end
    end
  end

  describe "#current_account" do
    context "when session exists" do
      it "returns the account from the jwt session with strict loading disabled" do
        token = "jwt-token"
        jwt_session = OpenStruct.new(account_id: account.id, active?: true)
        allow(api_token_manager).to receive(:bearer_token).and_return(token)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(jwt_session)

        result = session_manager.current_account
        expect(result).to eq(account)
        expect(result.strict_loading?).to be(false)
      end
    end

    context "when no session exists" do
      it "returns nil" do
        allow(api_token_manager).to receive(:bearer_token).and_return(nil)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(nil)

        result = session_manager.current_account
        expect(result).to be_nil
      end
    end
  end

  describe "#revoke_current_session!" do
    context "when session exists" do
      it "clears the cached session (JWT-based revoke)" do
        token = "jwt-token"
        jwt_session = OpenStruct.new(account_id: account.id, active?: true)
        allow(api_token_manager).to receive(:bearer_token).and_return(token)
        allow(api_token_manager).to receive(:verify_jwt_token).and_return(jwt_session)

        # Load the session first
        session_manager.current_session

        # Revoke just clears cache
        session_manager.revoke_current_session!

        expect(session_manager.instance_variable_get(:@current_session)).to be_nil
        expect(session_manager.instance_variable_get(:@current_account)).to be_nil
      end
    end

    context "when no session exists" do
      it "does nothing" do
        allow(api_token_manager).to receive(:bearer_token).and_return(nil)
        expect { session_manager.revoke_current_session! }.not_to raise_error
      end
    end
  end

  describe "#clear_session!" do
    it "clears the cached session" do
      session_manager.clear_session!
      expect(session_manager.instance_variable_get(:@current_session)).to be_nil
      expect(session_manager.instance_variable_get(:@current_account)).to be_nil
    end
  end
end
