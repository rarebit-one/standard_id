require "rails_helper"

RSpec.describe StandardId::Events do
  before do
    clear_event_subscribers!
  end

  after do
    clear_event_subscribers!
  end

  describe ".publish" do
    it "publishes an event with the given payload" do
      received_events = []

      described_class.subscribe("test.event") do |event|
        received_events << event
      end

      described_class.publish("test.event", foo: "bar", count: 42)

      expect(received_events.size).to eq(1)
      expect(received_events.first.payload[:foo]).to eq("bar")
      expect(received_events.first.payload[:count]).to eq(42)
    end

    it "adds standard metadata to the payload" do
      received_event = nil

      described_class.subscribe("test.event") do |event|
        received_event = event
      end

      described_class.publish("test.event", custom_data: "value")

      expect(received_event.payload[:event_type]).to eq("test.event")
      expect(received_event.payload[:event_id]).to be_present
      expect(received_event.payload[:timestamp]).to be_present
      expect(received_event.payload[:custom_data]).to eq("value")
    end

    it "enriches payload with Current context when available" do
      received_event = nil

      described_class.subscribe("test.event") do |event|
        received_event = event
      end

      account = Account.create!(name: "Test User", email: "test@example.com")

      Current.set(
        request_id: "req-123",
        ip_address: "192.168.1.1",
        user_agent: "Mozilla/5.0",
        account: account
      ) do
        described_class.publish("test.event", custom_data: "value")
      end

      expect(received_event.payload[:request_id]).to eq("req-123")
      expect(received_event.payload[:ip_address]).to eq("192.168.1.1")
      expect(received_event.payload[:user_agent]).to eq("Mozilla/5.0")
      expect(received_event.payload[:current_account]).to eq(account)
      expect(received_event.payload[:custom_data]).to eq("value")
    end

    it "does not add Current context when not set" do
      received_event = nil

      described_class.subscribe("test.event") do |event|
        received_event = event
      end

      Current.reset

      described_class.publish("test.event", custom_data: "value")

      expect(received_event.payload[:request_id]).to be_nil
      expect(received_event.payload[:ip_address]).to be_nil
      expect(received_event.payload[:user_agent]).to be_nil
      expect(received_event.payload[:current_account]).to be_nil
      expect(received_event.payload[:custom_data]).to eq("value")
    end


    it "namespaces the event name" do
      received_event = nil

      described_class.subscribe("standard_id.test.event") do |event|
        received_event = event
      end

      described_class.publish("test.event", data: "value")

      expect(received_event).to be_present
      expect(received_event.name).to eq("standard_id.test.event")
    end

    it "does not double-namespace already namespaced events" do
      received_event = nil

      described_class.subscribe("standard_id.already.namespaced") do |event|
        received_event = event
      end

      described_class.publish("standard_id.already.namespaced", data: "value")

      expect(received_event).to be_present
      expect(received_event.name).to eq("standard_id.already.namespaced")
    end

    context "with a block for lazy payload" do
      it "evaluates the block and merges with provided payload" do
        received_event = nil

        described_class.subscribe("test.event") do |event|
          received_event = event
        end

        described_class.publish("test.event", static: "value") do
          { dynamic: "computed" }
        end

        expect(received_event.payload[:static]).to eq("value")
        expect(received_event.payload[:dynamic]).to eq("computed")
      end
    end
  end

  describe ".subscribe" do
    it "returns a subscription handle" do
      subscription = described_class.subscribe("test.event") { |_| }

      expect(subscription).to be_present
    end

    it "receives events with the correct name" do
      received_names = []

      described_class.subscribe("test.specific.event") do |event|
        received_names << event.name
      end

      described_class.publish("test.specific.event", {})
      described_class.publish("test.other.event", {})

      expect(received_names).to eq(["standard_id.test.specific.event"])
    end

    it "supports pattern subscription with regex" do
      received_names = []

      described_class.subscribe(/authentication/) do |event|
        received_names << event.short_name
      end

      described_class.publish("authentication.succeeded", {})
      described_class.publish("authentication.failed", {})
      described_class.publish("session.created", {})

      expect(received_names).to contain_exactly("authentication.succeeded", "authentication.failed")
    end

    it "allows multiple subscribers for the same event" do
      subscriber1_calls = 0
      subscriber2_calls = 0

      described_class.subscribe("test.event") { |_| subscriber1_calls += 1 }
      described_class.subscribe("test.event") { |_| subscriber2_calls += 1 }

      described_class.publish("test.event", {})

      expect(subscriber1_calls).to eq(1)
      expect(subscriber2_calls).to eq(1)
    end
  end

  describe ".unsubscribe" do
    it "stops receiving events after unsubscription" do
      received_count = 0

      subscription = described_class.subscribe("test.event") do |_|
        received_count += 1
      end

      described_class.publish("test.event", {})
      expect(received_count).to eq(1)

      described_class.unsubscribe(subscription)

      described_class.publish("test.event", {})
      expect(received_count).to eq(1) # Should not increase
    end
  end

  describe ".namespaced_event_name" do
    it "adds the standard_id namespace prefix" do
      result = described_class.namespaced_event_name("test.event")

      expect(result).to eq("standard_id.test.event")
    end

    it "does not double-namespace" do
      result = described_class.namespaced_event_name("standard_id.test.event")

      expect(result).to eq("standard_id.test.event")
    end

    it "works with symbols" do
      result = described_class.namespaced_event_name(:test_event)

      expect(result).to eq("standard_id.test_event")
    end
  end

  describe "event constants" do
    it "defines authentication event constants" do
      expect(StandardId::Events::AUTHENTICATION_ATTEMPT_STARTED).to eq("authentication.attempt.started")
      expect(StandardId::Events::AUTHENTICATION_SUCCEEDED).to eq("authentication.attempt.succeeded")
      expect(StandardId::Events::AUTHENTICATION_FAILED).to eq("authentication.attempt.failed")
    end

    it "defines session event constants" do
      expect(StandardId::Events::SESSION_CREATING).to eq("session.creating")
      expect(StandardId::Events::SESSION_CREATED).to eq("session.created")
      expect(StandardId::Events::SESSION_REVOKED).to eq("session.revoked")
    end

    it "defines account event constants" do
      expect(StandardId::Events::ACCOUNT_CREATING).to eq("account.creating")
      expect(StandardId::Events::ACCOUNT_CREATED).to eq("account.created")
      expect(StandardId::Events::ACCOUNT_VERIFIED).to eq("account.verified")
    end

    it "defines OAuth event constants" do
      expect(StandardId::Events::OAUTH_TOKEN_ISSUING).to eq("oauth.token.issuing")
      expect(StandardId::Events::OAUTH_TOKEN_ISSUED).to eq("oauth.token.issued")
      expect(StandardId::Events::OAUTH_CODE_CONSUMED).to eq("oauth.code.consumed")
    end

    it "defines passwordless event constants" do
      expect(StandardId::Events::PASSWORDLESS_CODE_REQUESTED).to eq("passwordless.code.requested")
      expect(StandardId::Events::PASSWORDLESS_CODE_GENERATED).to eq("passwordless.code.generated")
      expect(StandardId::Events::PASSWORDLESS_CODE_SENT).to eq("passwordless.code.sent")
    end

    it "defines social event constants" do
      expect(StandardId::Events::SOCIAL_AUTH_STARTED).to eq("social.auth.started")
      expect(StandardId::Events::SOCIAL_AUTH_COMPLETED).to eq("social.auth.completed")
      expect(StandardId::Events::SOCIAL_ACCOUNT_CREATED).to eq("social.account.created")
    end

    it "groups events by category" do
      expect(StandardId::Events::AUTHENTICATION_EVENTS).to include(
        StandardId::Events::AUTHENTICATION_SUCCEEDED,
        StandardId::Events::AUTHENTICATION_FAILED
      )

      expect(StandardId::Events::SESSION_EVENTS).to include(
        StandardId::Events::SESSION_CREATED,
        StandardId::Events::SESSION_REVOKED
      )

      expect(StandardId::Events::ALL_EVENTS.size).to be > 30
    end
  end
end
