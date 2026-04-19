require "rails_helper"

RSpec.describe StandardId::SetCurrentRequestDetails do
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include StandardId::SetCurrentRequestDetails

      def index
        head :ok
      end
    end
  end

  let(:controller) { controller_class.new }
  let(:request_double) do
    instance_double(
      ActionDispatch::Request,
      request_id: "req-abc",
      remote_ip: "198.51.100.7",
      user_agent: "rspec-agent/1.0"
    )
  end

  # Captures every emitted event so specs can assert on name/payload/context
  # without squinting at closure plumbing.
  class CapturingSubscriber
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event)
      @events << event
    end
  end

  before do
    allow(controller).to receive(:request).and_return(request_double)

    stub_const(
      "Current",
      Class.new(ActiveSupport::CurrentAttributes) do
        attribute :request_id, :ip_address, :user_agent
      end
    )
  end

  after { Current.reset }

  describe "#set_current_request_details" do
    it "populates Current.* attributes from the request" do
      controller.send(:set_current_request_details)

      expect(::Current.request_id).to eq("req-abc")
      expect(::Current.ip_address).to eq("198.51.100.7")
      expect(::Current.user_agent).to eq("rspec-agent/1.0")
    end

    context "when Rails.event is available" do
      let(:subscriber) { CapturingSubscriber.new }

      before do
        skip "Rails.event not available on this Rails version" unless Rails.respond_to?(:event)
        Rails.event.clear_context
        Rails.event.subscribe(subscriber)
      end

      after do
        Rails.event.unsubscribe(subscriber) if Rails.respond_to?(:event)
        Rails.event.clear_context          if Rails.respond_to?(:event)
      end

      it "mirrors the request details into Rails.event context" do
        controller.send(:set_current_request_details)
        Rails.event.notify("rspec.probe")

        expect(subscriber.events.last[:context]).to include(
          request_id: "req-abc",
          ip_address: "198.51.100.7",
          user_agent: "rspec-agent/1.0"
        )
      end

      it "applies IpNormalizer output to the event context, not the raw remote_ip" do
        allow(request_double).to receive(:remote_ip).and_return("::ffff:198.51.100.7")

        controller.send(:set_current_request_details)
        Rails.event.notify("rspec.probe")

        expect(subscriber.events.last[:context][:ip_address])
          .to eq(StandardId::Utils::IpNormalizer.normalize("::ffff:198.51.100.7"))
      end

      it "omits fields when Current does not define them" do
        # Simulate a Current class that only exposes :request_id by masking
        # respond_to? for the other attributes. Using stub_const to swap in a
        # fresh anonymous CurrentAttributes subclass is unreliable here
        # because rspec-mocks keeps the previous subclass's generated methods
        # reachable through the ancestor chain.
        allow(::Current).to receive(:respond_to?).and_call_original
        allow(::Current).to receive(:respond_to?).with(:ip_address).and_return(false)
        allow(::Current).to receive(:respond_to?).with(:ip_address=).and_return(false)
        allow(::Current).to receive(:respond_to?).with(:user_agent).and_return(false)
        allow(::Current).to receive(:respond_to?).with(:user_agent=).and_return(false)

        controller.send(:set_current_request_details)
        Rails.event.notify("rspec.probe")

        context = subscriber.events.last[:context]
        expect(context[:request_id]).to eq("req-abc")
        expect(context[:ip_address]).to be_nil
        expect(context[:user_agent]).to be_nil
      end
    end

    context "when Rails.event is unavailable" do
      it "does not raise" do
        allow(Rails).to receive(:respond_to?).with(:event).and_return(false)

        expect { controller.send(:set_current_request_details) }.not_to raise_error
      end
    end
  end

  describe "#clear_rails_event_context" do
    context "when Rails.event is available" do
      before { skip "Rails.event not available on this Rails version" unless Rails.respond_to?(:event) }
      after  { Rails.event.clear_context }

      it "clears previously-set context so it cannot leak to the next request" do
        Rails.event.set_context(request_id: "stale-req")

        controller.send(:clear_rails_event_context)

        subscriber = CapturingSubscriber.new
        Rails.event.subscribe(subscriber)
        begin
          Rails.event.notify("rspec.probe")
        ensure
          Rails.event.unsubscribe(subscriber)
        end

        expect(subscriber.events.last[:context]).to be_empty
      end
    end

    context "when Rails.event is unavailable" do
      it "does not raise" do
        allow(Rails).to receive(:respond_to?).with(:event).and_return(false)

        expect { controller.send(:clear_rails_event_context) }.not_to raise_error
      end
    end
  end

  describe "callback registration" do
    it "registers set_current_request_details as a before_action" do
      filters = controller_class._process_action_callbacks.select { |c| c.kind == :before }.map(&:filter)
      expect(filters).to include(:set_current_request_details)
    end

    it "registers clear_rails_event_context as an after_action" do
      filters = controller_class._process_action_callbacks.select { |c| c.kind == :after }.map(&:filter)
      expect(filters).to include(:clear_rails_event_context)
    end
  end
end
