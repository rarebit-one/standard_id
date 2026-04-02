require "rails_helper"

RSpec.describe StandardId::AuthorizationBypass do
  # Create test controllers that mimic the real setup.
  # Define skip_verify_authorized as a no-op class method so that
  # ActionPolicy's class-method-based skip can be tested without
  # requiring the ActionPolicy gem itself.
  let(:public_controller) do
    Class.new(ActionController::Base) do
      include StandardId::ControllerPolicy
      public_controller

      def self.name
        "TestPublicController"
      end

      def self.skip_verify_authorized; end
    end
  end

  let(:authenticated_controller) do
    Class.new(ActionController::Base) do
      include StandardId::ControllerPolicy
      authenticated_controller

      def self.name
        "TestAuthenticatedController"
      end

      def self.skip_verify_authorized; end
    end
  end

  # Save/restore the global registry so we don't lose real controller
  # registrations that happen at class-load time.
  around do |example|
    saved = StandardId::ControllerPolicy.registry_snapshot
    StandardId::ControllerPolicy.reset_registry!
    public_controller
    authenticated_controller
    example.run
  ensure
    StandardId::AuthorizationBypass.reset!
    StandardId::ControllerPolicy.reset_registry!
    saved.each { |policy, set| set.each { |c| StandardId::ControllerPolicy.register(c, policy) } }
  end

  describe ".apply" do
    context "with framework: :action_policy" do
      it "calls skip_verify_authorized on all controllers" do
        expect(public_controller).to receive(:skip_verify_authorized).once
        expect(authenticated_controller).to receive(:skip_verify_authorized).once
        expect(public_controller).to receive(:skip_before_action).with(:authenticate_account!, raise: false).once

        described_class.apply(framework: :action_policy)
      end

      it "skips authenticate_account! only on public controllers" do
        allow(public_controller).to receive(:skip_verify_authorized)
        allow(authenticated_controller).to receive(:skip_verify_authorized)
        allow(public_controller).to receive(:skip_before_action)
        allow(authenticated_controller).to receive(:skip_before_action)

        described_class.apply(framework: :action_policy)

        expect(public_controller).to have_received(:skip_before_action).with(:authenticate_account!, raise: false)
        expect(authenticated_controller).not_to have_received(:skip_before_action)
      end
    end

    context "with framework: :pundit" do
      it "skips verify_authorized via skip_after_action on all controllers" do
        expect(public_controller).to receive(:skip_after_action).with(:verify_authorized, raise: false)
        expect(authenticated_controller).to receive(:skip_after_action).with(:verify_authorized, raise: false)
        expect(public_controller).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

        described_class.apply(framework: :pundit)
      end
    end

    context "with framework: :cancancan" do
      it "skips check_authorization via skip_before_action on all controllers" do
        expect(public_controller).to receive(:skip_before_action).with(:check_authorization, raise: false)
        expect(authenticated_controller).to receive(:skip_before_action).with(:check_authorization, raise: false)
        expect(public_controller).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

        described_class.apply(framework: :cancancan)
      end
    end

    context "with custom callback" do
      it "skips the specified callback via skip_before_action on all controllers" do
        expect(public_controller).to receive(:skip_before_action).with(:my_custom_auth, raise: false)
        expect(authenticated_controller).to receive(:skip_before_action).with(:my_custom_auth, raise: false)
        expect(public_controller).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

        described_class.apply(callback: :my_custom_auth)
      end
    end

    context "with both framework: and callback:" do
      it "raises ArgumentError" do
        expect {
          described_class.apply(framework: :action_policy, callback: :my_auth)
        }.to raise_error(ArgumentError, /not both/)
      end
    end

    context "with unknown framework" do
      it "raises ArgumentError" do
        expect { described_class.apply(framework: :unknown) }.to raise_error(ArgumentError, /Unknown framework/)
      end
    end

    context "with no arguments" do
      it "raises ArgumentError" do
        expect { described_class.apply }.to raise_error(ArgumentError, /Provide either/)
      end
    end

    context "when called twice (idempotency)" do
      it "does not error and only applies once" do
        allow(public_controller).to receive(:skip_verify_authorized)
        allow(authenticated_controller).to receive(:skip_verify_authorized)
        allow(public_controller).to receive(:skip_before_action)

        described_class.apply(framework: :action_policy)
        described_class.apply(framework: :action_policy)

        expect(public_controller).to have_received(:skip_verify_authorized).once
        expect(authenticated_controller).to have_received(:skip_verify_authorized).once
      end
    end
  end

  describe ".apply_to_controller" do
    it "calls skip_verify_authorized and skip_before_action :authenticate_account! for public controllers (action_policy)" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)
      described_class.apply(framework: :action_policy)

      new_public = Class.new(ActionController::Base) do
        def self.name = "NewPublicController"
        def self.skip_verify_authorized; end
      end

      expect(new_public).to receive(:skip_verify_authorized)
      expect(new_public).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

      described_class.apply_to_controller(new_public, :public)
    end

    it "calls skip_verify_authorized only for authenticated controllers (action_policy)" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)
      described_class.apply(framework: :action_policy)

      new_auth = Class.new(ActionController::Base) do
        def self.name = "NewAuthController"
        def self.skip_verify_authorized; end
      end

      expect(new_auth).to receive(:skip_verify_authorized)
      expect(new_auth).not_to receive(:skip_before_action).with(:authenticate_account!, raise: false)

      described_class.apply_to_controller(new_auth, :authenticated)
    end

    it "uses skip_after_action for pundit framework" do
      allow(public_controller).to receive(:skip_after_action)
      allow(authenticated_controller).to receive(:skip_after_action)
      allow(public_controller).to receive(:skip_before_action)
      described_class.apply(framework: :pundit)

      new_public = Class.new(ActionController::Base) do
        def self.name = "NewPunditController"
      end

      expect(new_public).to receive(:skip_after_action).with(:verify_authorized, raise: false)
      expect(new_public).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

      described_class.apply_to_controller(new_public, :public)
    end

    it "uses skip_before_action for cancancan framework" do
      allow(public_controller).to receive(:skip_before_action)
      allow(authenticated_controller).to receive(:skip_before_action)
      described_class.apply(framework: :cancancan)

      new_public = Class.new(ActionController::Base) do
        def self.name = "NewCanCanController"
      end

      expect(new_public).to receive(:skip_before_action).with(:check_authorization, raise: false)
      expect(new_public).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

      described_class.apply_to_controller(new_public, :public)
    end

    it "skips gracefully when controller does not respond to skip_verify_authorized (action_policy)" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)
      described_class.apply(framework: :action_policy)

      # Simulates an API controller that inherits from ActionController::API
      # and does not include ActionPolicy.
      api_controller = Class.new(ActionController::API) do
        def self.name = "ApiControllerWithoutActionPolicy"
      end

      expect { described_class.apply_to_controller(api_controller, :public) }.not_to raise_error
    end

    it "rescues ArgumentError when skip_verify_authorized raises (controller inherits method but has no callback)" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)
      described_class.apply(framework: :action_policy)

      # Simulates a controller that inherits ActionPolicy::Controller (and thus
      # responds to skip_verify_authorized) but has NOT called verify_authorized
      # itself, so there is no callback to skip.
      controller_with_inherited_method = Class.new(ActionController::Base) do
        def self.name = "InheritedActionPolicyController"

        def self.skip_verify_authorized
          raise ArgumentError, "After process_action callback :verify_authorized has not been defined"
        end
      end

      expect { described_class.apply_to_controller(controller_with_inherited_method, :authenticated) }.not_to raise_error
    end

    it "re-raises ArgumentError with a different message (not callback-related)" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)
      described_class.apply(framework: :action_policy)

      controller_with_bug = Class.new(ActionController::Base) do
        def self.name = "BuggyController"

        def self.skip_verify_authorized
          raise ArgumentError, "wrong number of arguments (given 2, expected 1)"
        end
      end

      expect { described_class.apply_to_controller(controller_with_bug, :authenticated) }.to raise_error(
        ArgumentError, "wrong number of arguments (given 2, expected 1)"
      )
    end

    it "is a no-op when apply has not been called" do
      new_controller = Class.new(ActionController::Base) do
        def self.name = "UnappliedController"
        def self.skip_verify_authorized; end
      end

      expect(new_controller).not_to receive(:skip_before_action)
      expect(new_controller).not_to receive(:skip_after_action)
      expect(new_controller).not_to receive(:skip_verify_authorized)

      described_class.apply_to_controller(new_controller, :public)
    end
  end

  describe ".applied?" do
    it "returns false before apply is called" do
      expect(described_class.applied?).to be false
    end

    it "returns true after apply is called" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)

      described_class.apply(framework: :action_policy)

      expect(described_class.applied?).to be true
    end

    it "returns false after reset!" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)

      described_class.apply(framework: :action_policy)
      described_class.reset!

      expect(described_class.applied?).to be false
    end
  end

  describe "to_prepare registration" do
    it "does not register another to_prepare block after reset! + apply" do
      allow(public_controller).to receive(:skip_verify_authorized)
      allow(authenticated_controller).to receive(:skip_verify_authorized)
      allow(public_controller).to receive(:skip_before_action)

      described_class.apply(framework: :action_policy)
      described_class.reset!

      # After reset!, apply should re-apply skips but NOT register another
      # to_prepare block. The @prepared flag survives reset!.
      expect(Rails.application.config).not_to receive(:to_prepare)

      allow(public_controller).to receive(:skip_after_action)
      allow(authenticated_controller).to receive(:skip_after_action)

      described_class.apply(framework: :pundit)
    end
  end

  describe "StandardId.skip_host_authorization" do
    it "delegates to AuthorizationBypass.apply" do
      expect(StandardId::AuthorizationBypass).to receive(:apply).with(framework: :action_policy, callback: nil)
      StandardId.skip_host_authorization(framework: :action_policy)
    end
  end

  describe "apply_skips! when ControllerPolicy is not yet autoloaded" do
    it "does not raise when ControllerPolicy is not defined" do
      # Simulate calling apply_skips! before Zeitwerk has autoloaded
      # ControllerPolicy (e.g. from a Rails initializer)
      allow(described_class).to receive(:apply_skips!).and_call_original
      hide_const("StandardId::ControllerPolicy")

      expect { described_class.apply_skips! }.not_to raise_error
    end
  end
end
