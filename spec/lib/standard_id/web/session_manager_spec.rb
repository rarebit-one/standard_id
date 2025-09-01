require "rails_helper"

RSpec.describe StandardId::Web::SessionManager do
  let(:session) { {} }
  let(:cookies) { {} }
  let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser") }
  let(:token_manager) { double("TokenManager") }
  let(:session_manager) { described_class.new(session, cookies, request, token_manager) }
  let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false, account: account) }
  let(:account) { double("Account") }

  before do
    allow(Current).to receive(:session).and_return(nil)
    allow(Current).to receive(:session=)
  end

  describe "#load_current_session" do
    context "when Current.session is present" do
      before do
        allow(Current).to receive(:session).and_return(browser_session)
      end

      it "returns Current.session without loading" do
        result = session_manager.load_current_session
        expect(result).to eq(browser_session)
      end
    end

    context "when session token exists" do
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        session[:session_token] = "valid_token"
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("valid_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(browser_session)
        # Mock Current.session= to actually store the value for subsequent calls
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
      end

      it "loads session from session token" do
        result = session_manager.load_current_session
        expect(result).to eq(browser_session)
      end

      it "sets Current.session" do
        expect(Current).to receive(:session=).with(browser_session)
        session_manager.load_current_session
      end
    end

    context "when remember token exists" do
      let(:password_credential) { double("PasswordCredential", account: account) }

      before do
        cookies[:remember_token] = "remember_token"
        allow(StandardId::PasswordCredential).to receive(:find_by_token_for)
          .with(:remember_me, "remember_token").and_return(password_credential)
        allow(token_manager).to receive(:create_browser_session)
          .with(account, remember_me: true).and_return(browser_session)
        allow(browser_session).to receive(:instance_variable_get).with(:@token).and_return("new_token")
        allow(token_manager).to receive(:create_remember_token)
        # Mock Current.session= to actually store the value for subsequent calls
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
      end

      it "creates new browser session from remember token" do
        expect(token_manager).to receive(:create_browser_session).with(account, remember_me: true)
        session_manager.load_current_session
      end

      it "sets session token" do
        session_manager.load_current_session
        expect(session[:session_token]).to eq("new_token")
      end

      it "creates new remember token" do
        expect(token_manager).to receive(:create_remember_token).with(password_credential, cookies)
        session_manager.load_current_session
      end
    end

    context "when session is expired" do
      let(:expired_session) { double("BrowserSession", expired?: true, revoked?: false) }
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        session[:session_token] = "expired_token"
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("expired_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(expired_session)
      end

      it "clears session and returns nil" do
        result = session_manager.load_current_session
        expect(result).to be_nil
        expect(session[:session_token]).to be_nil
      end
    end

    context "when session is revoked" do
      let(:revoked_session) { double("BrowserSession", expired?: false, revoked?: true) }
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        session[:session_token] = "revoked_token"
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("revoked_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(revoked_session)
      end

      it "clears session and returns nil" do
        result = session_manager.load_current_session
        expect(result).to be_nil
        expect(session[:session_token]).to be_nil
      end
    end
  end

  describe "#clear_session!" do
    before do
      session[:session_token] = "token"
      cookies[:remember_token] = "remember"
      allow(Current).to receive(:session=)
    end

    it "deletes session token" do
      session_manager.clear_session!
      expect(session[:session_token]).to be_nil
    end

    it "deletes remember token cookie" do
      session_manager.clear_session!
      expect(cookies[:remember_token]).to be_nil
    end

    it "clears Current.session" do
      expect(Current).to receive(:session=).with(nil)
      session_manager.clear_session!
    end
  end

  describe "#set_session_token" do
    it "sets session token" do
      session_manager.set_session_token("new_token")
      expect(session[:session_token]).to eq("new_token")
    end
  end

  describe "#session_token" do
    it "returns session token" do
      session[:session_token] = "test_token"
      expect(session_manager.session_token).to eq("test_token")
    end
  end
end
