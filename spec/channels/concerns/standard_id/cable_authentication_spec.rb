require "rails_helper"
require "action_cable"
# Pulls in ActionCable::Connection::TestSocket on Rails edge (8.2+); on released
# Rails this file simply doesn't define that constant. See connection_input below.
require "action_cable/connection/test_case"

RSpec.describe StandardId::CableAuthentication do
  let(:account) { Account.create!(name: "Test User", email: "test@example.com") }

  describe "connection authentication" do
    let(:connection_class) do
      Class.new(::ActionCable::Connection::Base) do
        include StandardId::CableAuthentication
      end
    end

    let(:server) do
      server = ::ActionCable::Server::Base.new
      server.config.logger = Logger.new(nil)
      server
    end

    let(:env) do
      Rack::MockRequest.env_for("/cable").tap do |e|
        e["HTTP_USER_AGENT"] = "RSpec Test Browser"
        e["REMOTE_ADDR"] = "127.0.0.1"
      end
    end
    let(:encrypted_cookies) { {} }
    let(:plain_cookies) { {} }
    let(:encrypted_cookies_mock) do
      double("EncryptedCookies").tap do |ec|
        allow(ec).to receive(:[]) { |key| encrypted_cookies[key] }
        allow(ec).to receive(:[]=) { |key, value| encrypted_cookies[key] = value }
      end
    end
    let(:mock_cookies) do
      double("Cookies").tap do |c|
        allow(c).to receive(:encrypted).and_return(encrypted_cookies_mock)
        allow(c).to receive(:[]) { |key| plain_cookies[key] }
        allow(c).to receive(:[]=) { |key, value| plain_cookies[key] = value }
      end
    end
    # Rails edge refactored ActionCable::Connection::Base to take a socket object
    # (which responds to #logger, #request, #env) as its second constructor
    # argument instead of the raw Rack env Hash. Wrap the env in a TestSocket when
    # that class is available so this spec runs against both released ActionCable
    # and the rails-edge canary.
    let(:connection_input) do
      if defined?(::ActionCable::Connection::TestSocket)
        request = ::ActionCable::Connection::TestSocket.build_request("/cable", env: env)
        ::ActionCable::Connection::TestSocket.new(request)
      else
        env
      end
    end
    let(:connection) do
      connection_class.new(server, connection_input).tap do |conn|
        allow(conn).to receive(:cookies).and_return(mock_cookies)
      end
    end

    context "with valid session token" do
      let(:browser_session) do
        StandardId::BrowserSession.create!(
          account: account,
          ip_address: "127.0.0.1",
          user_agent: "Test Browser",
          expires_at: 1.day.from_now
        )
      end

      it "successfully connects" do
        encrypted_cookies[:session_token] = browser_session.token

        connection.connect

        expect(connection.current_account).to eq(account)
      end
    end

    context "with expired session token" do
      let(:expired_session) do
        StandardId::BrowserSession.create!(
          account: account,
          ip_address: "127.0.0.1",
          user_agent: "Test Browser",
          expires_at: 1.day.ago
        )
      end

      it "rejects connection" do
        encrypted_cookies[:session_token] = expired_session.token

        expect {
          connection.connect
        }.to raise_error(::ActionCable::Connection::Authorization::UnauthorizedError)
      end
    end

    context "with revoked session token" do
      let(:revoked_session) do
        StandardId::BrowserSession.create!(
          account: account,
          ip_address: "127.0.0.1",
          user_agent: "Test Browser",
          expires_at: 1.day.from_now,
          revoked_at: Time.current
        )
      end

      it "rejects connection" do
        encrypted_cookies[:session_token] = revoked_session.token

        expect {
          connection.connect
        }.to raise_error(::ActionCable::Connection::Authorization::UnauthorizedError)
      end
    end

    context "without authentication" do
      it "rejects connection" do
        expect {
          connection.connect
        }.to raise_error(::ActionCable::Connection::Authorization::UnauthorizedError)
      end
    end

    context "with invalid session token" do
      it "rejects connection" do
        encrypted_cookies[:session_token] = "invalid_token"

        expect {
          connection.connect
        }.to raise_error(::ActionCable::Connection::Authorization::UnauthorizedError)
      end
    end
  end
end
