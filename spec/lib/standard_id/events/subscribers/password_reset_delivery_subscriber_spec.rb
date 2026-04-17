require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::PasswordResetDeliverySubscriber do
  let(:logger) { instance_double(Logger, error: nil) }

  before do
    clear_event_subscribers!
    allow(StandardId).to receive(:logger).and_return(logger)
  end

  after do
    clear_event_subscribers!
  end

  describe "event subscription" do
    it "subscribes to CREDENTIAL_PASSWORD_RESET_INITIATED" do
      expect(described_class.subscribed_events).to eq(
        [StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED]
      )
    end
  end

  describe "#call" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.credential.password.reset_initiated",
        payload: {
          event_type: "credential.password.reset_initiated",
          identifier: "user@example.com",
          account: double("Account", id: 1),
          token: "reset-token-abc",
          reset_url: "https://example.test/reset_password/confirm?token=reset-token-abc"
        }
      )
    end

    context "when delivery is :built_in" do
      before do
        allow(StandardId.config.reset_password).to receive(:delivery).and_return(:built_in)
      end

      it "enqueues a reset email via PasswordResetMailer" do
        mailer_double = double("ActionMailer::MessageDelivery")
        mail_double = double("Mail::Message")

        expect(StandardId::PasswordResetMailer).to receive(:with).with(
          email: "user@example.com",
          reset_url: "https://example.test/reset_password/confirm?token=reset-token-abc"
        ).and_return(mailer_double)
        expect(mailer_double).to receive(:reset_email).and_return(mail_double)
        expect(mail_double).to receive(:deliver_later)

        described_class.new.call(event)
      end

      context "when identifier is blank" do
        let(:event) do
          StandardId::Events::Event.new(
            name: "standard_id.credential.password.reset_initiated",
            payload: {
              event_type: "credential.password.reset_initiated",
              identifier: "",
              token: "t",
              reset_url: "https://example.test/?token=t"
            }
          )
        end

        it "does not send an email" do
          expect(StandardId::PasswordResetMailer).not_to receive(:with)
          described_class.new.call(event)
        end
      end

      context "when reset_url is blank" do
        let(:event) do
          StandardId::Events::Event.new(
            name: "standard_id.credential.password.reset_initiated",
            payload: {
              event_type: "credential.password.reset_initiated",
              identifier: "user@example.com",
              token: "t",
              reset_url: ""
            }
          )
        end

        it "does not send an email" do
          expect(StandardId::PasswordResetMailer).not_to receive(:with)
          described_class.new.call(event)
        end
      end
    end

    context "when delivery is :custom (default)" do
      before do
        allow(StandardId.config.reset_password).to receive(:delivery).and_return(:custom)
      end

      it "does not send an email" do
        expect(StandardId::PasswordResetMailer).not_to receive(:with)
        described_class.new.call(event)
      end
    end
  end

  describe "#handle_error" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.credential.password.reset_initiated",
        payload: { identifier: "user@example.com" }
      )
    end

    it "logs the error without re-raising" do
      error = StandardError.new("SMTP connection refused")

      expect(logger).to receive(:error).with(
        "[StandardId::PasswordResetDelivery] Failed to deliver password reset email " \
        "for user@example.com: SMTP connection refused"
      )

      expect { described_class.new.handle_error(error, event) }.not_to raise_error
    end
  end
end
