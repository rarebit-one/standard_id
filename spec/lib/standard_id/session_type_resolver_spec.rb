require "rails_helper"

RSpec.describe StandardId::SessionTypeResolver do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  let(:account) { double("Account", id: 1) }

  after do
    StandardId.config.session.session_type_resolver = nil
  end

  describe ".resolve!" do
    context "with the default resolver" do
      it "returns StandardId::BrowserSession for :web_sign_in" do
        expect(described_class.resolve!(request: request, account: account, flow: :web_sign_in))
          .to eq(StandardId::BrowserSession)
      end

      it "returns StandardId::DeviceSession for :api_device_auth" do
        expect(described_class.resolve!(request: request, account: account, flow: :api_device_auth))
          .to eq(StandardId::DeviceSession)
      end

      it "returns StandardId::ServiceSession for :api_service_auth" do
        expect(described_class.resolve!(request: request, account: account, flow: :api_service_auth))
          .to eq(StandardId::ServiceSession)
      end

      it "raises ConfigurationError when the flow maps to nil" do
        expect {
          described_class.resolve!(request: request, account: account, flow: :oauth_token_issued)
        }.to raise_error(StandardId::ConfigurationError, /returned nil for flow :oauth_token_issued/)
      end

      it "raises ConfigurationError for an unknown flow symbol (no silent :browser fallback)" do
        expect {
          described_class.resolve!(request: request, account: account, flow: :some_typo)
        }.to raise_error(StandardId::ConfigurationError, /unknown flow :some_typo/)
      end
    end

    context "with a custom resolver" do
      it "accepts a symbol return value and maps it to the class" do
        StandardId.config.session.session_type_resolver = ->(request:, account:, flow:) { :device }

        expect(described_class.resolve!(request: request, account: account, flow: :web_sign_in))
          .to eq(StandardId::DeviceSession)
      end

      it "accepts a class return value" do
        StandardId.config.session.session_type_resolver = lambda { |request:, account:, flow:|
          StandardId::ServiceSession
        }

        expect(described_class.resolve!(request: request, account: account, flow: :api_service_auth))
          .to eq(StandardId::ServiceSession)
      end

      it "receives the expected keyword arguments" do
        received = nil
        StandardId.config.session.session_type_resolver = lambda { |request:, account:, flow:|
          received = { request: request, account: account, flow: flow }
          :browser
        }

        described_class.resolve!(request: request, account: account, flow: :web_sign_in)

        expect(received).to eq(request: request, account: account, flow: :web_sign_in)
      end

      it "raises ConfigurationError for unknown symbol returns" do
        StandardId.config.session.session_type_resolver = ->(**) { :unknown_symbol }

        expect {
          described_class.resolve!(request: request, account: account, flow: :web_sign_in)
        }.to raise_error(StandardId::ConfigurationError, /unknown symbol :unknown_symbol/)
      end

      it "raises ConfigurationError for non-session-subclass class returns" do
        StandardId.config.session.session_type_resolver = ->(**) { String }

        expect {
          described_class.resolve!(request: request, account: account, flow: :web_sign_in)
        }.to raise_error(StandardId::ConfigurationError, /returned String/)
      end

      it "raises ConfigurationError for garbage return values" do
        StandardId.config.session.session_type_resolver = ->(**) { 42 }

        expect {
          described_class.resolve!(request: request, account: account, flow: :web_sign_in)
        }.to raise_error(StandardId::ConfigurationError, /returned 42/)
      end

      it "raises ConfigurationError when resolver is not callable" do
        StandardId.config.session.session_type_resolver = "not_callable"

        expect {
          described_class.resolve!(request: request, account: account, flow: :web_sign_in)
        }.to raise_error(StandardId::ConfigurationError, /must be callable/)
      end
    end
  end

  describe ".resolve_optional" do
    it "returns nil for flows the default resolver maps to nil" do
      expect(described_class.resolve_optional(request: request, account: account, flow: :oauth_token_issued))
        .to be_nil
    end

    it "returns the resolved class when the resolver elects to create a session" do
      StandardId.config.session.session_type_resolver = lambda { |request:, account:, flow:|
        flow == :oauth_token_issued ? :device : nil
      }

      expect(described_class.resolve_optional(request: request, account: account, flow: :oauth_token_issued))
        .to eq(StandardId::DeviceSession)
    end

    it "still raises on invalid non-nil returns" do
      StandardId.config.session.session_type_resolver = ->(**) { :unknown }

      expect {
        described_class.resolve_optional(request: request, account: account, flow: :oauth_token_issued)
      }.to raise_error(StandardId::ConfigurationError)
    end
  end
end
