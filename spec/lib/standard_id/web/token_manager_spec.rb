require "rails_helper"

RSpec.describe StandardId::Web::TokenManager do
  let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: false) }
  let(:token_manager) { described_class.new(request) }
  let(:account) { double("Account", id: 1) }
  let(:browser_session) { double("BrowserSession", instance_variable_get: "test_token") }
  let(:password_credential) { double("PasswordCredential", generate_token_for: "remember_token", expires_at: 1.month.from_now) }
  let(:cookies) { {} }

  describe "#create_browser_session" do
    before do
      allow(StandardId::BrowserSession).to receive(:create!).and_return(browser_session)
    end

    context "with default options" do
      it "creates a browser session with 24 hour expiry" do
        expect(StandardId::BrowserSession).to receive(:create!).with(
          account: account,
          ip_address: "127.0.0.1",
          user_agent: "Test Browser",
          expires_at: be_within(1.minute).of(24.hours.from_now)
        )

        token_manager.create_browser_session(account)
      end

      it "returns the created browser session" do
        result = token_manager.create_browser_session(account)
        expect(result).to eq(browser_session)
      end
    end

    context "with remember_me: true" do
      it "creates a browser session with 30 day expiry" do
        expect(StandardId::BrowserSession).to receive(:create!).with(
          account: account,
          ip_address: "127.0.0.1",
          user_agent: "Test Browser",
          expires_at: be_within(1.minute).of(30.days.from_now)
        )

        token_manager.create_browser_session(account, remember_me: true)
      end
    end
  end

  describe "#create_remember_token" do
    context "with non-SSL request" do
      it "sets remember token cookie with correct attributes" do
        token_manager.create_remember_token(password_credential, cookies)

        expect(cookies[:remember_token]).to eq({
          value: "remember_token",
          expires: password_credential.expires_at,
          httponly: true,
          secure: false,
          same_site: :lax
        })
      end
    end

    context "with SSL request" do
      let(:ssl_request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: true) }
      let(:ssl_token_manager) { described_class.new(ssl_request) }

      it "sets secure flag to true" do
        ssl_token_manager.create_remember_token(password_credential, cookies)

        expect(cookies[:remember_token][:secure]).to be true
      end
    end
  end

  describe "#sign_in_account" do
    let(:session_manager) { double("SessionManager") }

    before do
      allow(StandardId::BrowserSession).to receive(:create!).and_return(browser_session)
      allow(session_manager).to receive(:set_session_token)
      allow(Current).to receive(:session=)
    end

    it "creates a browser session" do
      expect(StandardId::BrowserSession).to receive(:create!).with(
        account: account,
        ip_address: "127.0.0.1",
        user_agent: "Test Browser",
        expires_at: be_within(1.minute).of(24.hours.from_now)
      )

      token_manager.sign_in_account(account, session_manager)
    end

    it "sets session token via session manager" do
      expect(session_manager).to receive(:set_session_token).with("test_token")
      token_manager.sign_in_account(account, session_manager)
    end

    it "sets Current.session" do
      expect(Current).to receive(:session=).with(browser_session)
      token_manager.sign_in_account(account, session_manager)
    end

    it "returns the browser session" do
      result = token_manager.sign_in_account(account, session_manager)
      expect(result).to eq(browser_session)
    end
  end
end
