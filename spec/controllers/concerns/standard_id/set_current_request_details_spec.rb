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
      before do
        skip "Rails.event not available on this Rails version" unless Rails.respond_to?(:event)
        Rails.event.clear_context
      end

      after { Rails.event.clear_context if Rails.respond_to?(:event) }

      it "mirrors the request details into Rails.event context" do
        controller.send(:set_current_request_details)

        captured = nil
        sub = Class.new { define_method(:emit) { |e| captured = e[:context] } }.new
        Rails.event.subscribe(sub)
        begin
          Rails.event.notify("rspec.probe")
        ensure
          Rails.event.unsubscribe(sub)
        end

        expect(captured).to include(
          request_id: "req-abc",
          ip_address: "198.51.100.7",
          user_agent: "rspec-agent/1.0"
        )
      end
    end

    context "when Rails.event is unavailable" do
      it "does not raise" do
        allow(Rails).to receive(:respond_to?).with(:event).and_return(false)

        expect { controller.send(:set_current_request_details) }.not_to raise_error
      end
    end
  end
end
