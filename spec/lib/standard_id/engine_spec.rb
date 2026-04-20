require "rails_helper"

RSpec.describe StandardId::Engine do
  describe "filter_parameters initializer" do
    it "filters OAuth-sensitive parameters" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      %w[code_verifier code_challenge client_secret id_token refresh_token access_token state nonce authorization_code].each do |param|
        filtered = filter.filter(param => "secret_value")
        expect(filtered[param]).to eq("[FILTERED]"), "Expected #{param} to be filtered"
      end
    end
  end

  describe ".verify_host_cookie_encryption!" do
    let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }

    before do
      allow(Rails).to receive(:logger).and_return(logger)
    end

    around do |example|
      original_env = ENV.fetch("SECRET_KEY_BASE", nil)
      ENV.delete("SECRET_KEY_BASE")
      example.run
    ensure
      ENV["SECRET_KEY_BASE"] = original_env if original_env
    end

    it "warns when neither ENV nor credentials provide a secret_key_base" do
      credentials = double("Credentials", secret_key_base: nil)
      app = double("App", credentials: credentials)
      expect(logger).to receive(:warn).with(a_string_including("secret_key_base"))

      described_class.verify_host_cookie_encryption!(app)
    end

    it "warns when credentials.secret_key_base is blank" do
      credentials = double("Credentials", secret_key_base: "")
      app = double("App", credentials: credentials)
      expect(logger).to receive(:warn).with(a_string_including("secret_key_base"))

      described_class.verify_host_cookie_encryption!(app)
    end

    it "does not warn when ENV['SECRET_KEY_BASE'] is set" do
      ENV["SECRET_KEY_BASE"] = "x" * 64
      app = double("App") # no credentials needed — ENV short-circuits
      expect(logger).not_to receive(:warn)

      described_class.verify_host_cookie_encryption!(app)
    end

    it "does not warn when credentials.secret_key_base is present" do
      credentials = double("Credentials", secret_key_base: "x" * 64)
      app = double("App", credentials: credentials)
      expect(logger).not_to receive(:warn)

      described_class.verify_host_cookie_encryption!(app)
    end

    it "does NOT call app.secret_key_base (which would trigger Rails' setter and can raise)" do
      # Regression test: earlier versions called `app.secret_key_base`, which
      # in Rails 8.1 runs the auto-generate+persist path. When that resolves
      # to blank, the setter raises, turning this defensive warning into a
      # hard boot failure under parallel workers. The fix reads ENV and
      # credentials directly instead.
      credentials = double("Credentials", secret_key_base: "x" * 64)
      app = double("App", credentials: credentials)
      # Intentionally NOT stubbing secret_key_base — if the engine tries to
      # call it, the double raises RSpec::Mocks::MockExpectationError for
      # unknown message, which fails the test.

      expect { described_class.verify_host_cookie_encryption!(app) }.not_to raise_error
    end

    it "treats a raising credentials lookup as 'not configured' (no propagation)" do
      credentials = double("Credentials")
      allow(credentials).to receive(:secret_key_base).and_raise(StandardError, "missing master key")
      app = double("App", credentials: credentials)
      expect(logger).to receive(:warn).with(a_string_including("secret_key_base"))

      expect { described_class.verify_host_cookie_encryption!(app) }.not_to raise_error
    end

    it "warns (and does not raise) when the app responds to neither credentials nor secret_key_base" do
      # Covers the `respond_to?(:credentials)` guard in host_secret_key_base.
      # A minimal double with no stubs at all: any method call would raise
      # RSpec's unknown-message error, so reaching this test without a raise
      # proves the probe never touches credentials or secret_key_base on an
      # app that doesn't expose them.
      app = double("App")
      expect(logger).to receive(:warn).with(a_string_including("secret_key_base"))

      expect { described_class.verify_host_cookie_encryption!(app) }.not_to raise_error
    end
  end

  describe ".warn_if_allowed_audiences_empty_in_production!" do
    let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }

    before { allow(Rails).to receive(:logger).and_return(logger) }

    context "in production with empty allowed_audiences" do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return([])
      end

      it "emits a warning about unenforced global audience" do
        expect(logger).to receive(:warn).with(/allowed_audiences is empty in production/)
        described_class.warn_if_allowed_audiences_empty_in_production!
      end

      it "mentions the cross-audience replay risk" do
        expect(logger).to receive(:warn).with(/cross-audience replay/)
        described_class.warn_if_allowed_audiences_empty_in_production!
      end
    end

    context "in production with allowed_audiences configured" do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[web api])
      end

      it "does not emit a warning" do
        expect(logger).not_to receive(:warn)
        described_class.warn_if_allowed_audiences_empty_in_production!
      end
    end

    context "in non-production environments with empty allowed_audiences" do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return([])
      end

      it "stays silent" do
        expect(logger).not_to receive(:warn)
        described_class.warn_if_allowed_audiences_empty_in_production!
      end
    end
  end

  describe "error hierarchy availability at engine load time" do
    # Host apps reference StandardId error classes at controller class-body
    # load time (e.g. `rescue_from StandardId::SocialLinkError, with: ...`).
    # If the errors file isn't required before the engine boots, they have
    # to fall back to string literals. All engine files require errors.rb
    # to guarantee the constants are defined once the engine is loaded.
    it "defines StandardId::SocialLinkError at engine load time" do
      expect(defined?(StandardId::SocialLinkError)).to eq("constant")
      expect(StandardId::SocialLinkError.ancestors).to include(StandardId::OAuthError)
    end

    it "defines the full error hierarchy at engine load time" do
      %w[
        NotAuthenticatedError
        InvalidSessionError
        AccountDeactivatedError
        AccountLockedError
        OAuthError
        AuthenticationDenied
        SocialLinkError
        InvalidAudienceError
      ].each do |klass_name|
        expect(StandardId.const_defined?(klass_name, false)).to be(true),
          "Expected StandardId::#{klass_name} to be defined at engine load time"
      end
    end

    it "allows rescue_from to resolve StandardId::SocialLinkError as a constant in a controller class body" do
      # Simulate a host app's application_controller.rb referring to
      # StandardId::SocialLinkError directly (not as a string literal).
      controller_class = Class.new(ActionController::Base) do
        rescue_from StandardId::SocialLinkError, with: :handle_social_link_error

        private

        def handle_social_link_error(_exception)
          # no-op
        end
      end

      # If the constant weren't available, Class.new would raise NameError above.
      handlers = controller_class.rescue_handlers
      expect(handlers.map(&:first)).to include("StandardId::SocialLinkError")
    end
  end
end
