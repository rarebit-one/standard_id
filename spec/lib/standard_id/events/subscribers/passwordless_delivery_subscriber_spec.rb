require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::PasswordlessDeliverySubscriber do
  let(:logger) { instance_double(Logger, error: nil) }
  let(:code_challenge) { double("CodeChallenge", code: "123456") }

  before do
    clear_event_subscribers!
    allow(StandardId).to receive(:logger).and_return(logger)
  end

  after do
    clear_event_subscribers!
  end

  describe "event subscription" do
    it "subscribes to PASSWORDLESS_CODE_GENERATED" do
      expect(described_class.subscribed_events).to eq(
        [StandardId::Events::PASSWORDLESS_CODE_GENERATED]
      )
    end
  end

  describe "#call" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.passwordless.code.generated",
        payload: {
          event_type: "passwordless.code.generated",
          identifier: "user@example.com",
          channel: "email",
          code_challenge: code_challenge,
          expires_at: 10.minutes.from_now
        }
      )
    end

    context "when delivery is :built_in" do
      before do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)
      end

      it "enqueues an OTP email via PasswordlessMailer" do
        mailer_double = double("ActionMailer::MessageDelivery")
        mail_double = double("Mail::Message")

        expect(StandardId::PasswordlessMailer).to receive(:with).with(
          email: "user@example.com",
          otp_code: "123456"
        ).and_return(mailer_double)
        expect(mailer_double).to receive(:otp_email).and_return(mail_double)
        expect(mail_double).to receive(:deliver_later)

        described_class.new.call(event)
      end

      context "when channel is not email" do
        let(:event) do
          StandardId::Events::Event.new(
            name: "standard_id.passwordless.code.generated",
            payload: {
              event_type: "passwordless.code.generated",
              identifier: "+15551234567",
              channel: "sms",
              code_challenge: code_challenge,
              expires_at: 10.minutes.from_now
            }
          )
        end

        it "does not send an email" do
          expect(StandardId::PasswordlessMailer).not_to receive(:with)

          described_class.new.call(event)
        end
      end

      context "when identifier is blank" do
        let(:event) do
          StandardId::Events::Event.new(
            name: "standard_id.passwordless.code.generated",
            payload: {
              event_type: "passwordless.code.generated",
              identifier: "",
              channel: "email",
              code_challenge: code_challenge,
              expires_at: 10.minutes.from_now
            }
          )
        end

        it "does not send an email" do
          expect(StandardId::PasswordlessMailer).not_to receive(:with)

          described_class.new.call(event)
        end
      end

      context "when code_challenge is nil" do
        let(:event) do
          StandardId::Events::Event.new(
            name: "standard_id.passwordless.code.generated",
            payload: {
              event_type: "passwordless.code.generated",
              identifier: "user@example.com",
              channel: "email",
              code_challenge: nil,
              expires_at: 10.minutes.from_now
            }
          )
        end

        it "does not send an email" do
          expect(StandardId::PasswordlessMailer).not_to receive(:with)

          described_class.new.call(event)
        end
      end
    end

    context "when delivery is :custom (default)" do
      before do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:custom)
      end

      it "does not send an email" do
        expect(StandardId::PasswordlessMailer).not_to receive(:with)

        described_class.new.call(event)
      end
    end
  end

  describe "#handle_error" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.passwordless.code.generated",
        payload: {
          identifier: "user@example.com"
        }
      )
    end

    it "logs the error without re-raising" do
      error = StandardError.new("SMTP connection refused")

      expect(logger).to receive(:error).with(
        "[StandardId::PasswordlessDelivery] Failed to deliver OTP email " \
        "for user@example.com: SMTP connection refused"
      )

      expect { described_class.new.handle_error(error, event) }.not_to raise_error
    end
  end

  describe "integration via event system" do
    before do
      allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)
      described_class.attach
    end

    it "triggers delivery when PASSWORDLESS_CODE_GENERATED is published" do
      mailer_double = double("ActionMailer::MessageDelivery")
      mail_double = double("Mail::Message")

      expect(StandardId::PasswordlessMailer).to receive(:with).with(
        email: "test@example.com",
        otp_code: "654321"
      ).and_return(mailer_double)
      expect(mailer_double).to receive(:otp_email).and_return(mail_double)
      expect(mail_double).to receive(:deliver_later)

      StandardId::Events.publish(
        StandardId::Events::PASSWORDLESS_CODE_GENERATED,
        identifier: "test@example.com",
        channel: "email",
        code_challenge: double("CodeChallenge", code: "654321"),
        expires_at: 10.minutes.from_now
      )
    end
  end
end
