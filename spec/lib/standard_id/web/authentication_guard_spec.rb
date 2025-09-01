require "rails_helper"

RSpec.describe StandardId::Web::AuthenticationGuard do
  let(:guard) { described_class.new }
  let(:session_manager) { double("SessionManager") }
  let(:session) { {} }
  let(:request) { double("Request", url: "http://example.com/protected") }
  let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false) }

  describe "#require_session!" do
    before do
      allow(Current).to receive(:session).and_return(nil)
      allow(Current).to receive(:session=)
    end

    context "when session is valid" do
      before do
        allow(session_manager).to receive(:load_current_session).and_return(browser_session)
      end

      it "sets return_to_after_authenticating in session" do
        guard.require_session!(session_manager, session, request)
        expect(session[:return_to_after_authenticating]).to eq("http://example.com/protected")
      end

      it "sets Current.session to the browser session" do
        expect(Current).to receive(:session=).with(browser_session)
        guard.require_session!(session_manager, session, request)
      end

      it "does not raise an error" do
        expect { guard.require_session!(session_manager, session, request) }.not_to raise_error
      end
    end

    context "when no session exists" do
      before do
        allow(session_manager).to receive(:load_current_session).and_return(nil)
      end

      it "raises NotAuthenticatedError" do
        expect { guard.require_session!(session_manager, session, request) }
          .to raise_error(StandardId::NotAuthenticatedError)
      end
    end

    context "when session is expired" do
      let(:expired_session) { double("BrowserSession", expired?: true, revoked?: false) }

      before do
        allow(session_manager).to receive(:load_current_session).and_return(expired_session)
        allow(session_manager).to receive(:clear_session!)
      end

      it "clears the session" do
        expect(session_manager).to receive(:clear_session!)
        expect { guard.require_session!(session_manager, session, request) }
          .to raise_error(StandardId::ExpiredSessionError)
      end

      it "raises ExpiredSessionError" do
        expect { guard.require_session!(session_manager, session, request) }
          .to raise_error(StandardId::ExpiredSessionError)
      end
    end

    context "when session is revoked" do
      let(:revoked_session) { double("BrowserSession", expired?: false, revoked?: true) }

      before do
        allow(session_manager).to receive(:load_current_session).and_return(revoked_session)
        allow(session_manager).to receive(:clear_session!)
      end

      it "clears the session" do
        expect(session_manager).to receive(:clear_session!)
        expect { guard.require_session!(session_manager, session, request) }
          .to raise_error(StandardId::RevokedSessionError)
      end

      it "raises RevokedSessionError" do
        expect { guard.require_session!(session_manager, session, request) }
          .to raise_error(StandardId::RevokedSessionError)
      end
    end
  end

  describe "#after_authentication_url" do
    it "returns and deletes return_to_after_authenticating from session" do
      session[:return_to_after_authenticating] = "http://example.com/dashboard"

      result = guard.after_authentication_url(session)

      expect(result).to eq("http://example.com/dashboard")
      expect(session[:return_to_after_authenticating]).to be_nil
    end

    it "returns default path when no return_to_after_authenticating exists" do
      result = guard.after_authentication_url(session)
      expect(result).to eq("/")
    end
  end
end
