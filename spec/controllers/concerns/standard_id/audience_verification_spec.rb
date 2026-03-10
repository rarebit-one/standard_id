require "rails_helper"

RSpec.describe StandardId::AudienceVerification do
  let(:account) { Account.create!(name: "Test User", email: "user@example.com") }

  describe "dependency guard" do
    it "raises if ApiAuthentication is not included" do
      expect {
        Class.new(ActionController::API) do
          include StandardId::AudienceVerification
        end
      }.to raise_error(RuntimeError, /must include StandardId::ApiAuthentication/)
    end
  end

  describe ".verify_audience" do
    it "sets the required audiences on the controller class" do
      controller_class = Class.new(ActionController::API) do
        include StandardId::ApiAuthentication
        include StandardId::AudienceVerification
        verify_audience "admin", "mobile"
      end

      expect(controller_class._required_audiences).to eq(%w[admin mobile])
    end

    it "defaults to an empty array when not configured" do
      controller_class = Class.new(ActionController::API) do
        include StandardId::ApiAuthentication
        include StandardId::AudienceVerification
      end

      expect(controller_class._required_audiences).to eq([])
    end
  end

  describe "#verify_audience!" do
    let(:session) do
      StandardId::JwtService.session_class.new(
        account_id: account.id,
        scopes: [],
        grant_type: "authorization_code",
        aud: token_audience
      )
    end

    let(:controller_class) do
      Class.new(ActionController::API) do
        include StandardId::ApiAuthentication
        include StandardId::AudienceVerification
        verify_audience "admin", "mobile"

        # Expose for testing
        public :verify_audience!
      end
    end

    let(:controller) { controller_class.new }

    before do
      session_manager = instance_double(StandardId::Api::SessionManager,
        current_session: session,
        current_account: account)
      allow(controller).to receive(:session_manager).and_return(session_manager)
    end

    context "when token audience matches a required audience" do
      let(:token_audience) { "admin" }

      it "does not raise" do
        expect { controller.verify_audience! }.not_to raise_error
      end
    end

    context "when token has an array audience with a match" do
      let(:token_audience) { %w[admin other] }

      it "does not raise" do
        expect { controller.verify_audience! }.not_to raise_error
      end
    end

    context "when token audience does not match" do
      let(:token_audience) { "other_app" }

      it "raises InvalidAudienceError" do
        expect { controller.verify_audience! }.to raise_error(StandardId::InvalidAudienceError) do |error|
          expect(error.required).to eq(%w[admin mobile])
          expect(error.actual).to eq(%w[other_app])
        end
      end
    end

    context "when token has no audience" do
      let(:token_audience) { nil }

      it "raises InvalidAudienceError" do
        expect { controller.verify_audience! }.to raise_error(StandardId::InvalidAudienceError)
      end
    end

    context "when current_session is nil (unauthenticated)" do
      let(:token_audience) { nil }

      before do
        session_manager = instance_double(StandardId::Api::SessionManager,
          current_session: nil,
          current_account: nil)
        allow(controller).to receive(:session_manager).and_return(session_manager)
      end

      it "returns without raising so the auth layer can handle 401" do
        expect { controller.verify_audience! }.not_to raise_error
      end
    end

    context "when no required audiences are configured" do
      let(:token_audience) { "anything" }

      let(:controller_class) do
        Class.new(ActionController::API) do
          include StandardId::ApiAuthentication
          include StandardId::AudienceVerification
          # No verify_audience call

          public :verify_audience!
        end
      end

      it "does not raise (allows all audiences)" do
        expect { controller.verify_audience! }.not_to raise_error
      end
    end
  end

  describe "#handle_invalid_audience" do
    let(:controller_class) do
      Class.new(ActionController::API) do
        include StandardId::ApiAuthentication
        include StandardId::AudienceVerification

        public :handle_invalid_audience
      end
    end

    let(:controller) { controller_class.new }

    it "renders a 403 Forbidden JSON response with static WWW-Authenticate header" do
      error = StandardId::InvalidAudienceError.new(required: %w[admin], actual: %w[mobile])

      response_headers = {}
      response_double = instance_double(ActionDispatch::Response)
      allow(response_double).to receive(:set_header) { |k, v| response_headers[k] = v }
      allow(controller).to receive(:response).and_return(response_double)

      json_body = nil
      allow(controller).to receive(:render) do |options|
        json_body = options[:json]
        expect(options[:status]).to eq(:forbidden)
      end

      controller.handle_invalid_audience(error)

      expect(json_body[:error]).to eq("insufficient_scope")
      expect(json_body[:error_description]).to include("admin")
      expect(response_headers["WWW-Authenticate"]).to eq(
        'Bearer error="insufficient_scope", error_description="The access token audience is not permitted for this resource"'
      )
    end

    it "does not interpolate raw aud values into the header" do
      error = StandardId::InvalidAudienceError.new(
        required: %w[admin],
        actual: ['x", evil="injected']
      )

      response_headers = {}
      response_double = instance_double(ActionDispatch::Response)
      allow(response_double).to receive(:set_header) { |k, v| response_headers[k] = v }
      allow(controller).to receive(:response).and_return(response_double)
      allow(controller).to receive(:render)

      controller.handle_invalid_audience(error)

      expect(response_headers["WWW-Authenticate"]).not_to include("injected")
    end
  end
end
