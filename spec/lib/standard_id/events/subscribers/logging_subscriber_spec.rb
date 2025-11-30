require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::LoggingSubscriber do
  let(:logger) { instance_double(Logger) }

  before do
    clear_event_subscribers!
    allow(StandardId).to receive(:logger).and_return(logger)
    allow(StandardId.config.events).to receive(:enable_logging).and_return(true)
  end

  after do
    clear_event_subscribers!
  end

  describe "event subscription" do
    it "subscribes to all standard_id events" do
      expect(described_class.subscription_pattern).to eq(/\Astandard_id\./)
    end
  end

  describe "#call" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.authentication.attempt.succeeded",
        payload: {
          event_type: "authentication.attempt.succeeded",
          account: double("Account", id: 123),
          auth_method: "password",
          ip_address: "192.168.1.1"
        },
        started_at: Time.current - 0.05,
        finished_at: Time.current
      )
    end

    it "logs the event with structured payload" do
      expect(logger).to receive(:info) do |payload|
        expect(payload).to be_a(Hash)
        expect(payload[:subject]).to eq("standard_id.authentication.attempt.succeeded")
        expect(payload[:severity]).to eq("info")
      end

      described_class.new.call(event)
    end

    it "includes account information in the payload" do
      expect(logger).to receive(:info) do |payload|
        expect(payload[:account_id]).to eq(123)
      end

      described_class.new.call(event)
    end

    it "includes auth method in the payload" do
      expect(logger).to receive(:info) do |payload|
        expect(payload[:auth_method]).to eq("password")
      end

      described_class.new.call(event)
    end

    it "includes IP address in the payload" do
      expect(logger).to receive(:info) do |payload|
        expect(payload[:ip_address]).to eq("192.168.1.1")
      end

      described_class.new.call(event)
    end

    it "includes duration when available" do
      expect(logger).to receive(:info) do |payload|
        expect(payload[:duration]).to be_a(Float)
      end

      described_class.new.call(event)
    end

    context "when logging is disabled" do
      before do
        allow(StandardId.config.events).to receive(:enable_logging).and_return(false)
      end

      it "does not log" do
        expect(logger).not_to receive(:info)

        described_class.new.call(event)
      end
    end

    context "with failed authentication event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.authentication.attempt.failed",
          payload: {
            event_type: "authentication.attempt.failed",
            account_lookup: "user@example.com",
            error_code: "invalid_credentials",
            ip_address: "10.0.0.1"
          }
        )
      end

      it "logs at warn level with structured payload" do
        expect(logger).to receive(:warn) do |payload|
          expect(payload[:subject]).to eq("standard_id.authentication.attempt.failed")
          expect(payload[:severity]).to eq("warn")
        end

        described_class.new.call(event)
      end

      it "includes login in payload" do
        expect(logger).to receive(:warn) do |payload|
          expect(payload[:login]).to eq("user@example.com")
        end

        described_class.new.call(event)
      end

      it "includes error code in payload" do
        expect(logger).to receive(:warn) do |payload|
          expect(payload[:error_code]).to eq("invalid_credentials")
        end

        described_class.new.call(event)
      end
    end

    context "with session event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.session.created",
          payload: {
            event_type: "session.created",
            account: double("Account", id: 456),
            session_type: "browser"
          }
        )
      end

      it "logs at info level" do
        expect(logger).to receive(:info) do |payload|
          expect(payload[:subject]).to eq("standard_id.session.created")
        end

        described_class.new.call(event)
      end

      it "includes session type in payload" do
        expect(logger).to receive(:info) do |payload|
          expect(payload[:session_type]).to eq("browser")
        end

        described_class.new.call(event)
      end
    end

    context "with OAuth event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.oauth.token.issued",
          payload: {
            event_type: "oauth.token.issued",
            grant_type: "authorization_code",
            client_id: "client-123"
          }
        )
      end

      it "includes grant type in payload" do
        expect(logger).to receive(:info) do |payload|
          expect(payload[:grant_type]).to eq("authorization_code")
        end

        described_class.new.call(event)
      end
    end

    context "with social login event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.social.auth.completed",
          payload: {
            event_type: "social.auth.completed",
            provider: "google",
            account: double("Account", id: 789)
          }
        )
      end

      it "includes provider in payload" do
        expect(logger).to receive(:info) do |payload|
          expect(payload[:provider]).to eq("google")
        end

        described_class.new.call(event)
      end
    end
  end

  describe "#handle_error" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.test.event",
        payload: {}
      )
    end

    it "logs the error as structured payload" do
      error = StandardError.new("Test error")

      expect(logger).to receive(:error) do |payload|
        expect(payload[:subject]).to eq("standard_id.logging_subscriber.error")
        expect(payload[:event_type]).to eq("test.event")
        expect(payload[:error]).to eq("Test error")
      end

      expect { described_class.new.handle_error(error, event) }.not_to raise_error
    end
  end

  describe "LOG_LEVELS constant" do
    it "defines appropriate log levels for different events" do
      expect(described_class::LOG_LEVELS["authentication.attempt.succeeded"]).to eq(:info)
      expect(described_class::LOG_LEVELS["authentication.attempt.failed"]).to eq(:warn)
      expect(described_class::LOG_LEVELS["session.created"]).to eq(:info)
      expect(described_class::LOG_LEVELS["session.revoked"]).to eq(:info)
      expect(described_class::LOG_LEVELS["account.locked"]).to eq(:warn)
    end

    it "uses debug as default for unknown events" do
      expect(described_class::DEFAULT_LOG_LEVEL).to eq(:debug)
    end
  end
end
