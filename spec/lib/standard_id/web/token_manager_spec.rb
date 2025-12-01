require "rails_helper"

RSpec.describe StandardId::Web::TokenManager do
  include ActiveSupport::Testing::TimeHelpers
  let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: false) }
  let(:token_manager) { described_class.new(request) }
  let(:account) { double("Account", id: 1) }
  let(:browser_session) { double("BrowserSession", instance_variable_get: "test_token") }
  let(:password_credential) { double("PasswordCredential", generate_token_for: "remember_token") }
  let(:cookies) { {} }

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

  describe "#create_remember_token" do
    context "with non-SSL request" do
      it "returns remember token hash with correct attributes" do
        travel_to(Time.current) do
          expected_expires = StandardId::BrowserSession.remember_me_expiry

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

          result = token_manager.create_remember_token(password_credential)

          expect(result[:secure]).to be true
          expect(result[:expires]).to eq(expected_expires)
        end
      end
    end
  end
end
