require "rails_helper"

RSpec.describe StandardId::SentryContext do
  let(:account) { Account.create!(name: "Test User", email: "user@example.com") }
  let(:session) { instance_double("Session", id: SecureRandom.uuid) }

  let(:controller_class) do
    Class.new(ActionController::Base) do
      include StandardId::SentryContext

      attr_accessor :current_account, :current_session

      # Simulate a simple action for testing
      def index
        head :ok
      end
    end
  end

  let(:controller) { controller_class.new }

  before do
    # Silence log output from ActionController
    controller_class.logger = Logger.new(nil) if controller_class.respond_to?(:logger=)
  end

  describe "callback timing" do
    it "registers as a before_action, not after_action" do
      before_filters = controller_class._process_action_callbacks.select { |c| c.kind == :before }.map(&:filter)
      after_filters = controller_class._process_action_callbacks.select { |c| c.kind == :after }.map(&:filter)

      expect(before_filters).to include(:set_standard_id_sentry_context)
      expect(after_filters).not_to include(:set_standard_id_sentry_context)
    end
  end

  describe "#set_standard_id_sentry_context" do
    context "when Sentry is defined and current_account is present" do
      before do
        stub_const("Sentry", Class.new { def self.set_user(context); end })
        controller.current_account = account
        controller.current_session = session
      end

      it "calls Sentry.set_user with account id" do
        expect(Sentry).to receive(:set_user).with(hash_including(id: account.id))

        controller.send(:set_standard_id_sentry_context)
      end

      it "includes session_id when current_session is present" do
        expect(Sentry).to receive(:set_user).with(hash_including(
          id: account.id,
          session_id: session.id
        ))

        controller.send(:set_standard_id_sentry_context)
      end
    end

    context "when Sentry is defined but current_session is nil" do
      before do
        stub_const("Sentry", Class.new { def self.set_user(context); end })
        controller.current_account = account
        controller.current_session = nil
      end

      it "calls Sentry.set_user with only account id" do
        expect(Sentry).to receive(:set_user).with(hash_including(id: account.id))

        controller.send(:set_standard_id_sentry_context)
      end
    end

    context "when Sentry is not defined" do
      before do
        controller.current_account = account
        # Ensure Sentry is not defined in this context
        hide_const("Sentry") if defined?(Sentry)
      end

      it "does not raise an error" do
        expect { controller.send(:set_standard_id_sentry_context) }.not_to raise_error
      end
    end

    context "when current_account is nil" do
      before do
        stub_const("Sentry", Class.new { def self.set_user(context); end })
        controller.current_account = nil
      end

      it "does not call Sentry.set_user" do
        expect(Sentry).not_to receive(:set_user)

        controller.send(:set_standard_id_sentry_context)
      end
    end

    context "when controller does not define current_account" do
      let(:bare_controller_class) do
        Class.new(ActionController::Base) do
          include StandardId::SentryContext

          def index
            head :ok
          end
        end
      end

      let(:bare_controller) { bare_controller_class.new }

      before do
        stub_const("Sentry", Class.new { def self.set_user(context); end })
        bare_controller_class.logger = Logger.new(nil) if bare_controller_class.respond_to?(:logger=)
      end

      it "does not call Sentry.set_user" do
        expect(Sentry).not_to receive(:set_user)

        bare_controller.send(:set_standard_id_sentry_context)
      end

      it "does not raise an error" do
        expect { bare_controller.send(:set_standard_id_sentry_context) }.not_to raise_error
      end
    end
  end
end
