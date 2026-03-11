require "rails_helper"

RSpec.describe StandardId::AuthorizationBypass do
  # Create test controllers that mimic the real setup
  let(:public_controller) do
    Class.new(ActionController::Base) do
      include StandardId::ControllerPolicy
      public_controller

      def self.name
        "TestPublicController"
      end
    end
  end

  let(:authenticated_controller) do
    Class.new(ActionController::Base) do
      include StandardId::ControllerPolicy
      authenticated_controller

      def self.name
        "TestAuthenticatedController"
      end
    end
  end

  # Save/restore the global registry so we don't lose real controller
  # registrations that happen at class-load time.
  around do |example|
    saved = StandardId::ControllerPolicy.registry.transform_values(&:dup)
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
      it "skips verify_authorized on all controllers" do
        expect(public_controller).to receive(:skip_before_action).with(:verify_authorized, raise: false).once
        expect(authenticated_controller).to receive(:skip_before_action).with(:verify_authorized, raise: false).once
        expect(public_controller).to receive(:skip_before_action).with(:authenticate_account!, raise: false).once

        described_class.apply(framework: :action_policy)
      end

      it "skips authenticate_account! only on public controllers" do
        allow(public_controller).to receive(:skip_before_action)
        allow(authenticated_controller).to receive(:skip_before_action)

        described_class.apply(framework: :action_policy)

        expect(public_controller).to have_received(:skip_before_action).with(:authenticate_account!, raise: false)
        expect(authenticated_controller).not_to have_received(:skip_before_action).with(:authenticate_account!, raise: false)
      end
    end

    context "with framework: :pundit" do
      it "skips verify_authorized on all controllers" do
        expect(public_controller).to receive(:skip_before_action).with(:verify_authorized, raise: false)
        expect(authenticated_controller).to receive(:skip_before_action).with(:verify_authorized, raise: false)
        expect(public_controller).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

        described_class.apply(framework: :pundit)
      end
    end

    context "with framework: :cancancan" do
      it "skips check_authorization on all controllers" do
        expect(public_controller).to receive(:skip_before_action).with(:check_authorization, raise: false)
        expect(authenticated_controller).to receive(:skip_before_action).with(:check_authorization, raise: false)
        expect(public_controller).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

        described_class.apply(framework: :cancancan)
      end
    end

    context "with custom callback" do
      it "skips the specified callback on all controllers" do
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
        allow(public_controller).to receive(:skip_before_action)
        allow(authenticated_controller).to receive(:skip_before_action)

        described_class.apply(framework: :action_policy)
        described_class.apply(framework: :action_policy)

        expect(public_controller).to have_received(:skip_before_action).with(:verify_authorized, raise: false).once
        expect(authenticated_controller).to have_received(:skip_before_action).with(:verify_authorized, raise: false).once
      end
    end
  end

  describe ".apply_to_controller" do
    it "skips the authorization callback and authenticate_account! for public controllers" do
      described_class.apply(framework: :action_policy)

      new_public = Class.new(ActionController::Base) do
        def self.name = "NewPublicController"
      end

      expect(new_public).to receive(:skip_before_action).with(:verify_authorized, raise: false)
      expect(new_public).to receive(:skip_before_action).with(:authenticate_account!, raise: false)

      described_class.apply_to_controller(new_public, :public)
    end

    it "skips only the authorization callback for authenticated controllers" do
      described_class.apply(framework: :action_policy)

      new_auth = Class.new(ActionController::Base) do
        def self.name = "NewAuthController"
      end

      expect(new_auth).to receive(:skip_before_action).with(:verify_authorized, raise: false)
      expect(new_auth).not_to receive(:skip_before_action).with(:authenticate_account!, raise: false)

      described_class.apply_to_controller(new_auth, :authenticated)
    end

    it "is a no-op when apply has not been called" do
      new_controller = Class.new(ActionController::Base) do
        def self.name = "UnappliedController"
      end

      expect(new_controller).not_to receive(:skip_before_action)

      described_class.apply_to_controller(new_controller, :public)
    end
  end

  describe ".applied?" do
    it "returns false before apply is called" do
      expect(described_class.applied?).to be false
    end

    it "returns true after apply is called" do
      allow(public_controller).to receive(:skip_before_action)
      allow(authenticated_controller).to receive(:skip_before_action)

      described_class.apply(framework: :action_policy)

      expect(described_class.applied?).to be true
    end

    it "returns false after reset!" do
      allow(public_controller).to receive(:skip_before_action)
      allow(authenticated_controller).to receive(:skip_before_action)

      described_class.apply(framework: :action_policy)
      described_class.reset!

      expect(described_class.applied?).to be false
    end
  end

  describe "to_prepare registration" do
    it "does not register another to_prepare block after reset! + apply" do
      allow(public_controller).to receive(:skip_before_action)
      allow(authenticated_controller).to receive(:skip_before_action)

      described_class.apply(framework: :action_policy)
      described_class.reset!

      # After reset!, apply should re-apply skips but NOT register another
      # to_prepare block. The @prepared flag survives reset!.
      expect(Rails.application.config).not_to receive(:to_prepare)

      described_class.apply(framework: :pundit)
    end
  end

  describe "StandardId.skip_host_authorization" do
    it "delegates to AuthorizationBypass.apply" do
      expect(StandardId::AuthorizationBypass).to receive(:apply).with(framework: :action_policy, callback: nil)
      StandardId.skip_host_authorization(framework: :action_policy)
    end
  end
end
