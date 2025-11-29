require "rails_helper"

RSpec.describe StandardId::InertiaSupport do
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include StandardId::InertiaSupport

      # Expose private methods for testing
      public :use_inertia?, :inertia_available?, :redirect_with_inertia

      # Define inertia_location for testing (normally provided by InertiaRails)
      def inertia_location(url); end
    end
  end

  let(:controller) { controller_class.new }
  let(:request) { double("Request", inertia?: false) }

  before do
    allow(controller).to receive(:request).and_return(request)
    allow(controller).to receive(:redirect_to)
  end

  describe "#use_inertia?" do
    context "when use_inertia config is true and InertiaRails is defined" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(true)
        stub_const("InertiaRails", Module.new)
      end

      it "returns true" do
        expect(controller.use_inertia?).to be_truthy
      end
    end

    context "when use_inertia config is false" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(false)
      end

      it "returns false" do
        expect(controller.use_inertia?).to be_falsey
      end
    end

    context "when InertiaRails is not defined" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(true)
        hide_const("InertiaRails") if defined?(InertiaRails)
      end

      it "returns false" do
        expect(controller.use_inertia?).to be_falsey
      end
    end
  end

  describe "#inertia_available?" do
    context "when InertiaRails is defined" do
      before do
        stub_const("InertiaRails", Module.new)
      end

      it "returns true" do
        expect(controller.inertia_available?).to be_truthy
      end
    end

    context "when InertiaRails is not defined" do
      before do
        hide_const("InertiaRails") if defined?(InertiaRails)
      end

      it "returns false" do
        expect(controller.inertia_available?).to be_falsey
      end
    end
  end

  describe "#redirect_with_inertia" do
    let(:url) { "https://example.com/oauth" }

    context "when Inertia is enabled and request is an Inertia request" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(true)
        stub_const("InertiaRails", Module.new)
        allow(request).to receive(:inertia?).and_return(true)
        allow(controller).to receive(:inertia_location)
      end

      it "calls inertia_location" do
        controller.redirect_with_inertia(url)
        expect(controller).to have_received(:inertia_location).with(url)
      end

      it "does not call redirect_to" do
        controller.redirect_with_inertia(url)
        expect(controller).not_to have_received(:redirect_to)
      end
    end

    context "when Inertia is disabled" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(false)
      end

      it "calls redirect_to with options" do
        controller.redirect_with_inertia(url, allow_other_host: true)
        expect(controller).to have_received(:redirect_to).with(url, allow_other_host: true)
      end
    end

    context "when request is not an Inertia request" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(true)
        stub_const("InertiaRails", Module.new)
        allow(request).to receive(:inertia?).and_return(false)
      end

      it "calls redirect_to" do
        controller.redirect_with_inertia(url, status: :see_other)
        expect(controller).to have_received(:redirect_to).with(url, status: :see_other)
      end
    end
  end
end
