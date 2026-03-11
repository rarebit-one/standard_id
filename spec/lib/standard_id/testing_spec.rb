require "rails_helper"
require "standard_id/testing"

# In host apps, place these two lines in rails_helper.rb (see StandardId::Testing docs).
# They are at file scope here to mirror that setup.
StandardId::Testing.setup_factory_bot!

# The gem's session/oauth factories declare `association :account, factory: :account`.
# Host apps provide their own :account factory; this is the dummy app's version.
require_relative "../../dummy/spec/factories/account"

RSpec.describe StandardId::Testing do
  include FactoryBot::Syntax::Methods

  describe ".setup_factory_bot!" do
    it "raises a helpful LoadError when factory_bot is not available" do
      allow(StandardId::Testing).to receive(:require).with("standard_id/testing/factory_bot")
        .and_raise(LoadError.new("cannot load such file -- factory_bot"))

      expect { StandardId::Testing.setup_factory_bot! }
        .to raise_error(LoadError, /requires the `factory_bot` gem/)
    end
  end

  describe "factories" do
    describe "sessions" do
      it "creates a browser session without explicit account" do
        session = create(:standard_id_browser_session)
        expect(session).to be_persisted
        expect(session).to be_a(StandardId::BrowserSession)
        expect(session.account).to be_present
        expect(session.user_agent).to be_present
      end

      it "creates an expired browser session" do
        session = create(:standard_id_browser_session, :expired)
        expect(session).to be_expired
      end

      it "creates a revoked browser session" do
        session = create(:standard_id_browser_session, :revoked)
        expect(session).to be_revoked
      end

      it "creates a device session without explicit account" do
        session = create(:standard_id_device_session)
        expect(session).to be_persisted
        expect(session).to be_a(StandardId::DeviceSession)
        expect(session.account).to be_present
        expect(session.device_id).to be_present
        expect(session.device_agent).to be_present
      end

      it "creates a stale device session" do
        session = create(:standard_id_device_session, :stale)
        expect(session).to be_stale
      end

      it "creates a service session without explicit owner" do
        session = create(:standard_id_service_session)
        expect(session).to be_persisted
        expect(session).to be_a(StandardId::ServiceSession)
        expect(session.owner).to be_present
        expect(session.service_name).to eq("test-service")
      end
    end

    describe "identifiers" do
      let(:account) { create(:account) }

      it "creates an email identifier" do
        identifier = create(:standard_id_email_identifier, account: account)
        expect(identifier).to be_persisted
        expect(identifier).to be_a(StandardId::EmailIdentifier)
      end

      it "creates a verified email identifier" do
        identifier = create(:standard_id_email_identifier, :verified, account: account)
        expect(identifier).to be_verified
      end

      it "creates a phone number identifier" do
        identifier = create(:standard_id_phone_number_identifier, account: account)
        expect(identifier).to be_persisted
        expect(identifier.value).to match(/\A\+1555/)
      end

      it "creates a username identifier" do
        identifier = create(:standard_id_username_identifier, account: account)
        expect(identifier).to be_persisted
        expect(identifier.value).to match(/\Auser_\d+\z/)
      end
    end

    describe "credentials" do
      it "creates a password credential" do
        credential = create(:standard_id_password_credential)
        expect(credential).to be_persisted
        expect(credential.authenticate("password123")).to be_truthy
      end

      it "creates a credential linking identifier and password" do
        account = create(:account)
        identifier = create(:standard_id_email_identifier, :verified, account: account)
        password_cred = create(:standard_id_password_credential, login: identifier.value)
        credential = create(:standard_id_credential, identifier: identifier, credentialable: password_cred)
        expect(credential).to be_persisted
        expect(credential.identifier).to eq(identifier)
      end
    end

    describe "oauth" do
      it "creates a client application without explicit owner" do
        app = create(:standard_id_client_application)
        expect(app).to be_persisted
        expect(app.owner).to be_present
        expect(app.client_id).to be_present
        expect(app).to be_active
      end

      it "creates a public client application" do
        app = create(:standard_id_client_application, :public_client)
        expect(app).to be_public
      end

      it "creates a code challenge" do
        challenge = create(:standard_id_code_challenge)
        expect(challenge).to be_persisted
        expect(challenge).to be_active
        expect(challenge.code).to match(/\A\d{6}\z/)
      end

      it "creates an expired code challenge" do
        challenge = create(:standard_id_code_challenge, :expired)
        expect(challenge).to be_expired
      end

      it "creates an authorization code lookupable by plaintext code" do
        account = create(:account)
        plaintext = SecureRandom.hex(20)
        code = create(:standard_id_authorization_code, account: account, plaintext_code: plaintext)
        expect(code).to be_persisted

        looked_up = StandardId::AuthorizationCode.lookup(plaintext)
        expect(looked_up).to eq(code)
      end

      it "creates a client secret credential" do
        secret = create(:standard_id_client_secret_credential)
        expect(secret).to be_persisted
        expect(secret).to be_active
      end
    end
  end

  describe "RequestHelpers" do
    include StandardId::Testing::RequestHelpers

    let(:account) { create(:account) }

    it "creates a browser session for integration tests" do
      session = create_browser_session(account)
      expect(session).to be_persisted
      expect(session).to be_a(StandardId::BrowserSession)
      expect(session.account).to eq(account)
      expect(session.ip_address).to eq("127.0.0.1")
    end

    it "builds a JWT token" do
      token = build_jwt(account: account, scope: "openid profile")
      decoded = StandardId::JwtService.decode(token)
      expect(decoded["sub"]).to eq(account.id)
      expect(decoded["scope"]).to eq("openid profile")
    end

    it "raises ArgumentError when neither account nor sub is provided" do
      expect { build_jwt }.to raise_error(ArgumentError, "account or sub must be provided")
    end

    it "builds a bearer auth header" do
      header = bearer_auth_header("my-token")
      expect(header).to eq("Authorization" => "Bearer my-token")
    end
  end

  describe "AuthenticationHelpers" do
    include StandardId::Testing::AuthenticationHelpers

    let(:account) { create(:account) }

    describe "#stub_web_authentication" do
      it "stubs all authentication methods on the given controller class" do
        stub_web_authentication(account: account)
        controller = ApplicationController.new

        expect(controller.current_account).to eq(account)
        expect(controller.send(:authenticated?)).to be true
        expect(controller.send(:authenticate_account!)).to be true
        expect(controller.send(:require_browser_session!)).to be true
      end

      it "stubs an unauthenticated state when account is nil" do
        stub_web_authentication(account: nil)
        controller = ApplicationController.new

        expect(controller.current_account).to be_nil
        expect(controller.send(:authenticated?)).to be false
      end
    end

    describe "#stub_api_authentication" do
      it "infers Api::BaseController when defined" do
        expect { stub_api_authentication(account: account) }.not_to raise_error
      end

      it "stubs current_account on an explicit controller class" do
        stub_api_authentication(account: account, controller_class: Api::BaseController)
        controller = Api::BaseController.new

        expect(controller.current_account).to eq(account)
        expect(controller.send(:authenticated?)).to be true
      end
    end
  end
end
