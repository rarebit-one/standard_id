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
  end
end
