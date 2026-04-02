require "rails_helper"

RSpec.describe StandardId::InertiaRendering do
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include StandardId::InertiaRendering

      # Simulate controller context
      def self.name
        "StandardId::Web::LoginController"
      end

      attr_accessor :action_name

      # Expose private methods for testing
      public :render_with_inertia, :inertia_component_name, :auth_page_props
    end
  end

  let(:controller) { controller_class.new }
  let(:request) { double("Request", inertia?: false) }
  let(:flash) { { notice: nil, alert: nil } }

  before do
    allow(controller).to receive(:request).and_return(request)
    allow(controller).to receive(:flash).and_return(flash)
    allow(controller).to receive(:render)
    controller.action_name = "show"
  end

  describe "#inertia_component_name" do
    context "with default namespace" do
      before do
        allow(StandardId.config).to receive(:inertia_component_namespace).and_return(nil)
      end

      it "generates component name with default namespace" do
        expect(controller.inertia_component_name).to eq("standard_id/login/show")
      end

      it "uses provided action" do
        expect(controller.inertia_component_name(:create)).to eq("standard_id/login/create")
      end
    end

    context "with custom namespace" do
      before do
        allow(StandardId.config).to receive(:inertia_component_namespace).and_return("Auth")
      end

      it "generates component name with custom namespace" do
        expect(controller.inertia_component_name).to eq("Auth/login/show")
      end
    end
  end

  describe "#render_with_inertia" do
    context "when Inertia is enabled" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(true)
        allow(StandardId.config).to receive(:inertia_component_namespace).and_return("Auth")
        stub_const("InertiaRails", Module.new)
      end

      it "renders with inertia" do
        controller.render_with_inertia(props: { user: "test" })

        expect(controller).to have_received(:render).with(
          inertia: "Auth/login/show",
          props: { user: "test" },
          status: :ok
        )
      end

      it "uses custom component name when provided" do
        controller.render_with_inertia(component: "Custom/Component", props: {})

        expect(controller).to have_received(:render).with(
          inertia: "Custom/Component",
          props: {},
          status: :ok
        )
      end

      it "passes status code" do
        controller.render_with_inertia(props: {}, status: :unprocessable_entity)

        expect(controller).to have_received(:render).with(
          inertia: "Auth/login/show",
          props: {},
          status: :unprocessable_entity
        )
      end
    end

    context "when Inertia is disabled" do
      before do
        allow(StandardId.config).to receive(:use_inertia).and_return(false)
      end

      it "renders with standard Rails rendering" do
        controller.render_with_inertia(props: { user: "test" })

        expect(controller).to have_received(:render).with(status: :ok)
      end

      it "includes action when specified" do
        controller.render_with_inertia(action: :show, props: {})

        expect(controller).to have_received(:render).with(status: :ok, action: :show)
      end
    end
  end

  describe "#auth_page_props" do
    before do
      controller.instance_variable_set(:@redirect_uri, "/dashboard")
      controller.instance_variable_set(:@connection, "google")
      allow(StandardId.config).to receive(:google_client_id).and_return("google-id")
      allow(StandardId.config).to receive(:apple_client_id).and_return(nil)
    end

    it "builds common auth props" do
      props = controller.auth_page_props

      expect(props[:redirect_uri]).to eq("/dashboard")
      expect(props[:connection]).to eq("google")
      expect(props[:social_providers][:google_enabled]).to be true
      expect(props[:social_providers][:apple_enabled]).to be false
    end

    it "merges additional props" do
      props = controller.auth_page_props(errors: { email: ["is invalid"] })

      expect(props[:errors]).to eq(email: ["is invalid"])
      expect(props[:redirect_uri]).to eq("/dashboard")
    end

    it "includes flash messages" do
      allow(controller).to receive(:flash).and_return({ notice: "Success!", alert: nil })

      props = controller.auth_page_props

      expect(props[:flash][:notice]).to eq("Success!")
      expect(props[:flash]).not_to have_key(:alert)
    end
  end
end
