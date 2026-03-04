require "rails_helper"

RSpec.describe StandardId::Web::SessionManager do
  let(:session) { {} }
  let(:encrypted_cookies) { {} }
  let(:plain_cookies) { {} }
  let(:encrypted_cookies_mock) do
    double("EncryptedCookies").tap do |ec|
      allow(ec).to receive(:[]) { |key| encrypted_cookies[key] }
      allow(ec).to receive(:[]=) { |key, value| encrypted_cookies[key] = value }
      allow(ec).to receive(:delete) { |key| encrypted_cookies.delete(key) }
    end
  end
  let(:cookies) do
    double("Cookies").tap do |c|
      allow(c).to receive(:encrypted).and_return(encrypted_cookies_mock)
      allow(c).to receive(:[]) { |key| plain_cookies[key] }
      allow(c).to receive(:[]=) { |key, value| plain_cookies[key] = value }
      allow(c).to receive(:delete) { |key| plain_cookies.delete(key) }
    end
  end
  let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser") }
  let(:token_manager) { double("TokenManager") }
  let(:session_manager) { described_class.new(token_manager, request: request, session: session, cookies: cookies) }
  let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false, account: account) }
  let(:account) { double("Account") }

  before do
    allow(Current).to receive(:session).and_return(nil)
    allow(Current).to receive(:session=)
  end

  describe "#current_session" do
    context "when Current.session is present" do
      before do
        allow(Current).to receive(:session).and_return(browser_session)
      end

      it "returns Current.session without loading" do
        result = session_manager.current_session
        expect(result).to eq(browser_session)
      end
    end

    context "when session token exists" do
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        encrypted_cookies[:session_token] = "valid_token"
        allow(StandardId::BrowserSession).to receive(:by_token).with("valid_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(browser_session)
        # Mock Current.session= to actually store the value for subsequent calls
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
      end

      it "loads session from session token" do
        result = session_manager.current_session
        expect(result).to eq(browser_session)
      end

      it "sets Current.session" do
        expect(Current).to receive(:session=).with(browser_session)
        session_manager.current_session
      end
    end

    context "when remember token exists" do
      let(:password_credential) { double("PasswordCredential", account: account) }

      before do
        plain_cookies[:remember_token] = "remember_token"
        allow(StandardId::PasswordCredential).to receive(:find_by_token_for)
          .with(:remember_me, "remember_token").and_return(password_credential)
        allow(token_manager).to receive(:create_browser_session).with(account, remember_me: true).and_return(browser_session)
        allow(browser_session).to receive(:token).and_return("token_value")
        allow(token_manager).to receive(:create_remember_token).with(password_credential).and_return({ value: "new_remember_token" })
        # Mock Current.session= to actually store the value for subsequent calls
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
      end

      it "creates new browser session from remember token" do
        result = session_manager.current_session
        expect(result).to eq(browser_session)
        expect(token_manager).to have_received(:create_browser_session).with(account, remember_me: true)
      end

      it "sets session token in encrypted cookie" do
        session_manager.current_session
        expect(encrypted_cookies[:session_token]).to eq("token_value")
      end

      it "creates new remember token" do
        session_manager.current_session
        expect(plain_cookies[:remember_token]).to eq({ value: "new_remember_token" })
      end
    end

    context "when session is expired" do
      let(:expired_session) { double("BrowserSession", expired?: true, revoked?: false) }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        encrypted_cookies[:session_token] = "expired_token"
        allow(StandardId::BrowserSession).to receive(:by_token).with("expired_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(expired_session)
      end

      it "clears session and returns nil" do
        result = session_manager.current_session
        expect(result).to be_nil
        expect(encrypted_cookies[:session_token]).to be_nil
      end
    end

    context "when session is revoked" do
      let(:revoked_session) { double("BrowserSession", expired?: false, revoked?: true) }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        encrypted_cookies[:session_token] = "revoked_token"
        allow(StandardId::BrowserSession).to receive(:by_token).with("revoked_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(revoked_session)
      end

      it "clears session and returns nil" do
        result = session_manager.current_session
        expect(result).to be_nil
        expect(encrypted_cookies[:session_token]).to be_nil
      end
    end
  end

  describe "#clear_session!" do
    before do
      encrypted_cookies[:session_token] = "token"
      plain_cookies[:remember_token] = "remember"
      allow(Current).to receive(:session=)
    end

    it "deletes session token cookie" do
      session_manager.clear_session!
      expect(encrypted_cookies[:session_token]).to be_nil
    end

    it "deletes remember token cookie" do
      session_manager.clear_session!
      expect(plain_cookies[:remember_token]).to be_nil
    end

    it "clears Current.session" do
      expect(Current).to receive(:session=).with(nil)
      session_manager.clear_session!
    end
  end
end
