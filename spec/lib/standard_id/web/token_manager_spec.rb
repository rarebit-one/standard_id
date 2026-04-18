require "rails_helper"

RSpec.describe StandardId::Web::TokenManager do
  include ActiveSupport::Testing::TimeHelpers
  let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: false) }
  let(:token_manager) { described_class.new(request) }
  let(:account) { double("Account", id: 1) }
  let(:browser_session) { double("BrowserSession", instance_variable_get: "test_token") }
  let(:password_credential) { double("PasswordCredential", generate_token_for: "remember_token") }
  let(:cookies) { {} }

  after { StandardId.config.session.session_type_resolver = nil }

  describe "#create_browser_session" do
    before do
      allow(StandardId::BrowserSession).to receive(:create!).and_return(browser_session)
    end

    context "with default options" do
      it "creates a browser session with configured expiry" do
        expect(StandardId::BrowserSession).to receive(:create!).with(
          account: account,
          ip_address: "127.0.0.1",
          user_agent: "Test Browser",
          expires_at: be_within(1.minute).of(StandardId::BrowserSession.expiry)
        )

        token_manager.create_browser_session(account)
      end

      it "returns the created browser session" do
        result = token_manager.create_browser_session(account)
        expect(result).to eq(browser_session)
      end
    end
  end

  describe "#create_browser_session with session_type_resolver override" do
    let(:real_account) { Account.create!(name: "User", email: "user@example.com") }
    let(:real_request) do
      instance_double(
        ActionDispatch::Request,
        remote_ip: "127.0.0.1",
        user_agent: "AdminKit/1.0 Android",
        ssl?: false
      )
    end
    let(:real_token_manager) { described_class.new(real_request) }

    it "defaults to BrowserSession when the resolver is not configured" do
      session = real_token_manager.create_browser_session(real_account)
      expect(session).to be_a(StandardId::BrowserSession)
      expect(session.user_agent).to eq("AdminKit/1.0 Android")
    end

    it "creates a DeviceSession when the resolver returns :device for :web_sign_in" do
      StandardId.config.session.session_type_resolver = lambda { |request:, account:, flow:|
        flow == :web_sign_in && request.user_agent.to_s.include?("AdminKit") ? :device : :browser
      }

      session = real_token_manager.create_browser_session(real_account)

      expect(session).to be_a(StandardId::DeviceSession)
      expect(session.device_agent).to eq("AdminKit/1.0 Android")
      expect(session.device_id).to be_present
    end

    it "raises ConfigurationError if resolver returns a session class with incompatible attrs (e.g. :service)" do
      StandardId.config.session.session_type_resolver = ->(**) { :service }

      expect { real_token_manager.create_browser_session(real_account) }
        .to raise_error(StandardId::ConfigurationError, /web sign-in cannot infer the attributes/)
    end
  end

  describe "#create_remember_token" do
    context "with non-SSL request" do
      it "returns remember token hash with correct attributes" do
        travel_to(Time.current) do
          expected_expires = StandardId::BrowserSession.remember_me_expiry
          allow(password_credential).to receive(:expires_at).and_return(expected_expires)

          result = token_manager.create_remember_token(password_credential)

          expect(result).to eq({
            value: "remember_token",
            expires: expected_expires,
            httponly: true,
            secure: false,
            same_site: :lax
          })
        end
      end
    end

    context "with SSL request" do
      let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: true) }

      it "sets secure flag to true" do
        travel_to(Time.current) do
          expected_expires = StandardId.config.session.browser_session_remember_me_lifetime.seconds.from_now
          allow(password_credential).to receive(:expires_at).and_return(expected_expires)

          result = token_manager.create_remember_token(password_credential)

          expect(result[:secure]).to be true
          expect(result[:expires]).to eq(expected_expires)
        end
      end
    end
  end
end
