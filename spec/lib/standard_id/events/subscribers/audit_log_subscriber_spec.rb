require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::AuditLogSubscriber do
  let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil) }

  before do
    clear_event_subscribers!
    allow(StandardId).to receive(:logger).and_return(logger)
    allow(logger).to receive(:error)
    allow(StandardId.config.events).to receive(:enable_audit_log).and_return(true)
  end

  after do
    clear_event_subscribers!
  end

  describe "DEFAULT_AUDIT_EVENTS constant" do
    it "includes authentication events" do
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("authentication.attempt.succeeded")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("authentication.attempt.failed")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("authentication.password.failed")
    end

    it "includes session events" do
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("session.created")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("session.revoked")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("session.expired")
    end

    it "includes account events" do
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("account.created")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("account.status_changed")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("account.locked")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("account.unlocked")
    end

    it "includes credential events" do
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("credential.password.created")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("credential.password.changed")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("credential.password.reset_completed")
    end

    it "includes oauth events" do
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("oauth.authorization.granted")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("oauth.authorization.denied")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("oauth.token.issued")
    end

    it "includes social events" do
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("social.account.created")
      expect(described_class::DEFAULT_AUDIT_EVENTS).to include("social.account.linked")
    end
  end

  describe ".audit_events" do
    it "returns DEFAULT_AUDIT_EVENTS when no custom events configured" do
      allow(StandardId.config.events).to receive(:audit_events).and_return(nil)
      expect(described_class.audit_events).to eq(described_class::DEFAULT_AUDIT_EVENTS)
    end

    it "returns configured events when set" do
      custom_events = ["authentication.attempt.succeeded", "session.created"]
      allow(StandardId.config.events).to receive(:audit_events).and_return(custom_events)
      expect(described_class.audit_events).to eq(custom_events)
    end
  end

  describe "#call" do
    let(:account) { Account.create!(name: "Test User", email: "audit-test-#{SecureRandom.hex(8)}@example.com") }
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.authentication.attempt.succeeded",
        payload: {
          event_type: "authentication.attempt.succeeded",
          event_id: SecureRandom.uuid,
          timestamp: Time.current.iso8601,
          account: account,
          auth_method: "password",
          ip_address: "192.168.1.1",
          user_agent: "Mozilla/5.0"
        },
        started_at: Time.current - 0.05,
        finished_at: Time.current
      )
    end

    it "creates an audit log record for security events" do
      expect { described_class.new.call(event) }.to change(StandardId::AuditLog, :count).by(1)
    end

    it "stores the correct event type" do
      described_class.new.call(event)

      audit_log = StandardId::AuditLog.last
      expect(audit_log.event_type).to eq("authentication.attempt.succeeded")
    end

    it "stores the actor" do
      described_class.new.call(event)

      audit_log = StandardId::AuditLog.last
      expect(audit_log.actor).to eq(account)
      expect(audit_log.actor_type).to eq("Account")
    end

    it "stores the IP address" do
      described_class.new.call(event)

      audit_log = StandardId::AuditLog.last
      expect(audit_log.ip_address).to eq("192.168.1.1")
    end

    it "stores metadata including auth_method" do
      described_class.new.call(event)

      audit_log = StandardId::AuditLog.last
      expect(audit_log.metadata["auth_method"]).to eq("password")
    end

    it "stores duration in metadata when available" do
      described_class.new.call(event)

      audit_log = StandardId::AuditLog.last
      expect(audit_log.metadata["duration_ms"]).to be_a(Float)
    end

    context "with failed authentication event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.authentication.attempt.failed",
          payload: {
            event_type: "authentication.attempt.failed",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            account_lookup: "user@example.com",
            error_code: "invalid_credentials",
            error_message: "Password is incorrect",
            ip_address: "10.0.0.1"
          }
        )
      end

      it "creates an audit log record" do
        expect { described_class.new.call(event) }.to change(StandardId::AuditLog, :count).by(1)
      end

      it "stores error information in metadata" do
        described_class.new.call(event)

        audit_log = StandardId::AuditLog.last
        expect(audit_log.metadata["error_code"]).to eq("invalid_credentials")
        expect(audit_log.metadata["error_message"]).to eq("Password is incorrect")
      end

      it "does not require an actor" do
        described_class.new.call(event)

        audit_log = StandardId::AuditLog.last
        expect(audit_log.actor).to be_nil
      end
    end

    context "with session event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.session.created",
          payload: {
            event_type: "session.created",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            account: account,
            session_type: "browser",
            ip_address: "192.168.1.1"
          }
        )
      end

      it "stores session type in metadata" do
        described_class.new.call(event)

        audit_log = StandardId::AuditLog.last
        expect(audit_log.metadata["session_type"]).to eq("browser")
      end
    end

    context "with OAuth event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.oauth.token.issued",
          payload: {
            event_type: "oauth.token.issued",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            account: account,
            grant_type: "authorization_code",
            client_id: "client-123"
          }
        )
      end

      it "stores grant type and client id in metadata" do
        described_class.new.call(event)

        audit_log = StandardId::AuditLog.last
        expect(audit_log.metadata["grant_type"]).to eq("authorization_code")
        expect(audit_log.metadata["client_id"]).to eq("client-123")
      end
    end

    context "with account status change event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.account.status_changed",
          payload: {
            event_type: "account.status_changed",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            account: account,
            old_status: "active",
            new_status: "inactive"
          }
        )
      end

      it "stores status change in metadata" do
        described_class.new.call(event)

        audit_log = StandardId::AuditLog.last
        expect(audit_log.metadata["old_status"]).to eq("active")
        expect(audit_log.metadata["new_status"]).to eq("inactive")
      end
    end

    context "with account locked event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.account.locked",
          payload: {
            event_type: "account.locked",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            account: account,
            lock_reason: "too_many_failed_attempts"
          }
        )
      end

      it "stores lock reason in metadata" do
        described_class.new.call(event)

        audit_log = StandardId::AuditLog.last
        expect(audit_log.metadata["lock_reason"]).to eq("too_many_failed_attempts")
      end
    end

    context "with social login event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.social.account.created",
          payload: {
            event_type: "social.account.created",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            account: account,
            provider: "google"
          }
        )
      end

      it "stores provider in metadata" do
        described_class.new.call(event)

        audit_log = StandardId::AuditLog.last
        expect(audit_log.metadata["provider"]).to eq("google")
      end
    end
  end

  describe "#handle_error" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.authentication.attempt.succeeded",
        payload: {
          event_type: "authentication.attempt.succeeded",
          event_id: SecureRandom.uuid
        }
      )
    end

    it "logs the error with structured payload" do
      error = StandardError.new("Database connection failed")

      expect(logger).to receive(:error) do |payload|
        expect(payload[:subject]).to eq("standard_id.audit_log_subscriber.error")
        expect(payload[:event_type]).to eq("authentication.attempt.succeeded")
        expect(payload[:error]).to eq("Database connection failed")
      end

      expect { described_class.new.handle_error(error, event) }.not_to raise_error
    end
  end
end
