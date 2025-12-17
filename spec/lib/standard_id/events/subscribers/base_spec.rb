require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::Base do
  before do
    clear_event_subscribers!
  end

  after do
    clear_event_subscribers!
  end

  describe ".subscribe_to" do
    it "registers event names to subscribe to" do
      test_class = Class.new(described_class) do
        subscribe_to "test.event.one", "test.event.two"
      end

      expect(test_class.subscribed_events).to eq(["test.event.one", "test.event.two"])
    end
  end

  describe ".subscribe_to_pattern" do
    it "registers a pattern to subscribe to" do
      test_class = Class.new(described_class) do
        subscribe_to_pattern(/authentication/)
      end

      expect(test_class.subscription_pattern).to eq(/authentication/)
    end
  end

  describe ".attach" do
    it "subscribes to the specified events" do
      received_events = []

      test_class = Class.new(described_class) do
        subscribe_to "test.subscriber.event"

        define_method(:call) do |event|
          received_events << event.short_name
        end
      end

      test_class.attach

      StandardId::Events.publish("test.subscriber.event", data: "value")

      expect(received_events).to eq(["test.subscriber.event"])
    end

    it "subscribes to pattern when using subscribe_to_pattern" do
      received_events = []

      test_class = Class.new(described_class) do
        subscribe_to_pattern(/test\.pattern/)

        define_method(:call) do |event|
          received_events << event.short_name
        end
      end

      test_class.attach

      StandardId::Events.publish("test.pattern.one", {})
      StandardId::Events.publish("test.pattern.two", {})
      StandardId::Events.publish("other.event", {})

      expect(received_events).to contain_exactly("test.pattern.one", "test.pattern.two")
    end

    it "returns subscription handles" do
      test_class = Class.new(described_class) do
        subscribe_to "test.event"
        define_method(:call) { |_| }
      end

      subscriptions = test_class.attach

      expect(subscriptions).not_to be_empty
    end

    it "marks the subscriber as attached" do
      test_class = Class.new(described_class) do
        subscribe_to "test.event"
        define_method(:call) { |_| }
      end

      expect(test_class.attached?).to be_falsey
      test_class.attach
      expect(test_class.attached?).to be true
    end
  end

  describe ".detach" do
    it "removes all subscriptions" do
      received_events = []

      test_class = Class.new(described_class) do
        subscribe_to "test.detach.event"

        define_method(:call) do |event|
          received_events << event.short_name
        end
      end

      test_class.attach
      StandardId::Events.publish("test.detach.event", {})
      expect(received_events.size).to eq(1)

      test_class.detach

      StandardId::Events.publish("test.detach.event", {})
      expect(received_events.size).to eq(1) # Should not increase
    end

    it "marks the subscriber as not attached" do
      test_class = Class.new(described_class) do
        subscribe_to "test.event"
        define_method(:call) { |_| }
      end

      test_class.attach
      expect(test_class.attached?).to be true

      test_class.detach
      expect(test_class.attached?).to be false
    end
  end

  describe "#handle" do
    it "calls the call method with the event" do
      received_event = nil

      test_class = Class.new(described_class) do
        define_method(:call) do |event|
          received_event = event
        end
      end

      event = StandardId::Events::Event.new(
        name: "test.event",
        payload: { data: "value" }
      )

      test_class.new.handle(event)

      expect(received_event).to eq(event)
    end

    it "catches errors and calls handle_error" do
      error_received = nil

      test_class = Class.new(described_class) do
        define_method(:call) do |_event|
          raise StandardError, "Test error"
        end

        define_method(:handle_error) do |error, _event|
          error_received = error
          # Don't re-raise in this test
        end
      end

      event = StandardId::Events::Event.new(name: "test.event", payload: {})

      test_class.new.handle(event)

      expect(error_received).to be_a(StandardError)
      expect(error_received.message).to eq("Test error")
    end
  end

  describe "#call" do
    it "raises NotImplementedError when not overridden" do
      event = StandardId::Events::Event.new(name: "test.event", payload: {})

      expect {
        described_class.new.call(event)
      }.to raise_error(NotImplementedError)
    end
  end

  describe "#handle_error" do
    it "logs the error and re-raises by default" do
      allow(StandardId).to receive(:logger).and_return(double("Logger", error: nil))

      event = StandardId::Events::Event.new(name: "test.event", payload: {})
      error = StandardError.new("Test error")

      expect(StandardId.logger).to receive(:error).with(/Error in.*handling test.event/)

      expect {
        described_class.new.handle_error(error, event)
      }.to raise_error(StandardError, "Test error")
    end
  end
end
