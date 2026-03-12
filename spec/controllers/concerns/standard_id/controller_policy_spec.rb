require "rails_helper"

RSpec.describe StandardId::ControllerPolicy do
  describe "controller classifications" do
    describe "public controllers" do
      let(:expected_public_controllers) do
        [
          StandardId::Web::LoginController,
          StandardId::Web::LoginVerifyController,
          StandardId::Web::SignupController,
          StandardId::Web::Auth::Callback::ProvidersController,
          StandardId::Web::ResetPassword::StartController,
          StandardId::Web::ResetPassword::ConfirmController,
          StandardId::Web::VerifyEmail::BaseController,
          StandardId::Web::VerifyEmail::StartController,
          StandardId::Web::VerifyEmail::ConfirmController,
          StandardId::Web::VerifyPhone::BaseController,
          StandardId::Web::VerifyPhone::StartController,
          StandardId::Web::VerifyPhone::ConfirmController,
          StandardId::Api::AuthorizationController,
          StandardId::Api::Oauth::TokensController,
          StandardId::Api::Oauth::Callback::ProvidersController,
          StandardId::Api::Oidc::LogoutController,
          StandardId::Api::WellKnown::JwksController,
          StandardId::Api::PasswordlessController
        ]
      end

      it "has a non-empty expected list (guards against vacuous pass under lazy loading)" do
        expect(expected_public_controllers).not_to be_empty
        expect(StandardId::ControllerPolicy.public_controllers).not_to be_empty
      end

      it "registers all public controllers" do
        expected_public_controllers.each do |controller|
          expect(StandardId::ControllerPolicy.public_controllers).to include(controller),
            "Expected #{controller} to be registered as public"
        end
      end

      it "sets the policy attribute on public controllers" do
        expected_public_controllers.each do |controller|
          expect(controller._standard_id_auth_policy).to eq(:public),
            "Expected #{controller}._standard_id_auth_policy to be :public"
        end
      end
    end

    describe "authenticated controllers" do
      let(:expected_authenticated_controllers) do
        [
          StandardId::Web::AccountController,
          StandardId::Web::SessionsController,
          StandardId::Web::LogoutController,
          StandardId::Api::UserinfoController
        ]
      end

      it "has a non-empty expected list (guards against vacuous pass under lazy loading)" do
        expect(expected_authenticated_controllers).not_to be_empty
        expect(StandardId::ControllerPolicy.authenticated_controllers).not_to be_empty
      end

      it "registers all authenticated controllers" do
        expected_authenticated_controllers.each do |controller|
          expect(StandardId::ControllerPolicy.authenticated_controllers).to include(controller),
            "Expected #{controller} to be registered as authenticated"
        end
      end

      it "sets the policy attribute on authenticated controllers" do
        expected_authenticated_controllers.each do |controller|
          expect(controller._standard_id_auth_policy).to eq(:authenticated),
            "Expected #{controller}._standard_id_auth_policy to be :authenticated"
        end
      end
    end

    it "does not overlap between public and authenticated" do
      overlap = StandardId::ControllerPolicy.public_controllers &
                StandardId::ControllerPolicy.authenticated_controllers
      expect(overlap).to be_empty
    end

    describe ".register" do
      it "is a no-op when re-registering under the same policy" do
        controller = Class.new(ActionController::Base) do
          include StandardId::ControllerPolicy
          def self.name = "SamePolicyController"
        end

        saved = StandardId::ControllerPolicy.registry.transform_values(&:dup)
        begin
          StandardId::ControllerPolicy.register(controller, :public)
          StandardId::ControllerPolicy.register(controller, :public)
          matches = StandardId::ControllerPolicy.public_controllers.select { |c| c == controller }
          expect(matches.size).to eq(1)
        ensure
          StandardId::ControllerPolicy.reset_registry!
          saved.each { |policy, set| set.each { |c| StandardId::ControllerPolicy.register(c, policy) } }
        end
      end

      it "raises ArgumentError when registering a controller with a conflicting policy" do
        controller = Class.new(ActionController::Base) do
          include StandardId::ControllerPolicy
          def self.name = "DualPolicyController"
        end

        saved = StandardId::ControllerPolicy.registry.transform_values(&:dup)
        begin
          StandardId::ControllerPolicy.register(controller, :public)
          expect {
            StandardId::ControllerPolicy.register(controller, :authenticated)
          }.to raise_error(ArgumentError, /already registered as public/)
        ensure
          StandardId::ControllerPolicy.reset_registry!
          saved.each { |policy, set| set.each { |c| StandardId::ControllerPolicy.register(c, policy) } }
        end
      end
    end

    describe ".all_controllers" do
      it "returns the union of public and authenticated controllers" do
        all = StandardId::ControllerPolicy.all_controllers
        expect(all).to include(*StandardId::ControllerPolicy.public_controllers)
        expect(all).to include(*StandardId::ControllerPolicy.authenticated_controllers)
      end
    end
  end
end
