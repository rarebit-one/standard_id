require "rails_helper"

RSpec.describe StandardId::Web::AuthenticationGuard do
  let(:session_manager) { double("SessionManager") }
  let(:session) { {} }
  let(:request) { double("Request", url: "http://example.com/protected", remote_ip: "127.0.0.1") }
  let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false, account: double("Account")) }
  let(:guard) { described_class.new }

  describe "#require_session!" do
    before do
      allow(Current).to receive(:session).and_return(nil)
      allow(Current).to receive(:session=)
    end

    context "when session is valid" do
      before do
        allow(session_manager).to receive(:current_session).and_return(browser_session)
      end

      it "sets return_to_after_authenticating in session" do
        result = guard.require_session!(session_manager, session: session, request: request)
        expect(session[:return_to_after_authenticating]).to eq("http://example.com/protected")
        expect(result).to eq(browser_session)
      end

      it "sets Current.session to the browser session" do
        result = guard.require_session!(session_manager, session: session, request: request)
        expect(result).to eq(browser_session)
      end

      it "does not raise an error" do
        expect { guard.require_session!(session_manager, session: session, request: request) }.not_to raise_error
      end
    end

    context "when no session exists" do
      it "raises NotAuthenticatedError" do
        allow(session_manager).to receive(:current_session).and_return(nil)

        expect {
          guard.require_session!(session_manager, session: session, request: request)
        }.to raise_error(StandardId::NotAuthenticatedError)
      end
    end

    context "when session is expired" do
      let(:expired_session) { double("BrowserSession", expired?: true, revoked?: false, account: double("Account"), expires_at: 1.hour.ago) }

      before do
        allow(session_manager).to receive(:current_session).and_return(expired_session)
        allow(session_manager).to receive(:clear_session!)
      end

      it "clears the session" do
        allow(session_manager).to receive(:current_session).and_return(expired_session)
        expect(session_manager).to receive(:clear_session!)
        expect {
          guard.require_session!(session_manager, session: session, request: request)
        }.to raise_error(StandardId::ExpiredSessionError)
      end

      it "raises ExpiredSessionError" do
        allow(session_manager).to receive(:current_session).and_return(expired_session)
        allow(session_manager).to receive(:clear_session!)
        expect {
          guard.require_session!(session_manager, session: session, request: request)
        }.to raise_error(StandardId::ExpiredSessionError)
      end
    end

    context "when session is revoked" do
      let(:revoked_session) { double("BrowserSession", expired?: false, revoked?: true) }

      before do
        allow(session_manager).to receive(:current_session).and_return(revoked_session)
        allow(session_manager).to receive(:clear_session!)
      end

      it "clears the session" do
        allow(session_manager).to receive(:current_session).and_return(revoked_session)
        expect(session_manager).to receive(:clear_session!)
        expect {
          guard.require_session!(session_manager, session: session, request: request)
        }.to raise_error(StandardId::RevokedSessionError)
      end

      it "raises RevokedSessionError" do
        allow(session_manager).to receive(:current_session).and_return(revoked_session)
        allow(session_manager).to receive(:clear_session!)
        expect {
          guard.require_session!(session_manager, session: session, request: request)
        }.to raise_error(StandardId::RevokedSessionError)
      end
    end
  end
end
