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
      # Default: no audience_profile_types binding (back-compat path)
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({})
      allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(nil)
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

  describe "audience_profile_types enforcement" do
    # Use a PORO account-like double so we can stub #profiles. The gem's
    # AudienceProfileResolver only requires #profiles on the account; it does
    # not rely on anything else from the Account model.
    let(:account) { double("AccountLike", id: 42, profiles: []) }

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
        verify_audience "admin_kit", "companion_kit", "harness"

        public :verify_audience!
      end
    end

    let(:controller) { controller_class.new }

    def build_profile(type, active: true)
      double("Profile", profileable_type: type, active?: active)
    end

    def stub_session_and_account(profiles: [])
      session_manager = instance_double(StandardId::Api::SessionManager,
        current_session: session,
        current_account: account)
      allow(controller).to receive(:session_manager).and_return(session_manager)
      allow(account).to receive(:profiles).and_return(profiles)
    end

    before do
      allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(nil)
    end

    context "when audience_profile_types is not configured" do
      let(:token_audience) { "admin_kit" }

      before do
        allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({})
        stub_session_and_account(profiles: [])
      end

      it "skips the profile-type check (back-compat)" do
        expect { controller.verify_audience! }.not_to raise_error
      end
    end

    context "when audience_profile_types maps admin_kit -> PlatformProfile" do
      before do
        allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
          "admin_kit"     => "PlatformProfile",
          "companion_kit" => "DeviceUserProfile"
        )
      end

      context "and the account has a matching PlatformProfile" do
        let(:token_audience) { "admin_kit" }

        before do
          stub_session_and_account(profiles: [build_profile("PlatformProfile")])
        end

        it "does not raise" do
          expect { controller.verify_audience! }.not_to raise_error
        end
      end

      context "and the account has no PlatformProfile" do
        let(:token_audience) { "admin_kit" }

        before do
          stub_session_and_account(profiles: [build_profile("DeviceUserProfile")])
        end

        it "raises InvalidAudienceProfileError" do
          expect { controller.verify_audience! }
            .to raise_error(StandardId::InvalidAudienceProfileError) do |error|
              expect(error.audience).to eq("admin_kit")
              expect(error.expected_profile_types).to eq(["PlatformProfile"])
              expect(error.actual_profile_type).to eq("DeviceUserProfile")
            end
        end

        it "emits the oauth.audience.mismatch event" do
          payloads = []
          unsubscribe = StandardId::Events.subscribe(StandardId::Events::OAUTH_AUDIENCE_MISMATCH) do |event|
            payloads << event.payload
          end

          expect { controller.verify_audience! }.to raise_error(StandardId::InvalidAudienceProfileError)

          expect(payloads.size).to eq(1)
          expect(payloads.first[:audience]).to eq("admin_kit")
          expect(payloads.first[:expected_profile_types]).to eq(["PlatformProfile"])
          expect(payloads.first[:actual_profile_type]).to eq("DeviceUserProfile")
        ensure
          ActiveSupport::Notifications.unsubscribe(unsubscribe) if unsubscribe
        end
      end

      context "and the account has no profiles at all" do
        let(:token_audience) { "admin_kit" }

        before { stub_session_and_account(profiles: []) }

        it "raises InvalidAudienceProfileError with a nil actual_profile_type" do
          expect { controller.verify_audience! }
            .to raise_error(StandardId::InvalidAudienceProfileError) do |error|
              expect(error.actual_profile_type).to be_nil
            end
        end
      end

      context "and the matched audience is not in the profile-type map" do
        let(:token_audience) { "harness" }

        before { stub_session_and_account(profiles: []) }

        it "skips the check for that audience" do
          expect { controller.verify_audience! }.not_to raise_error
        end
      end
    end

    context "multi-type mapping (audience -> [ProfileA, ProfileB])" do
      let(:token_audience) { "harness" }

      before do
        allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
          "harness" => ["PlatformProfile", "DeviceUserProfile"]
        )
      end

      it "accepts either configured profile type" do
        stub_session_and_account(profiles: [build_profile("DeviceUserProfile")])

        expect { controller.verify_audience! }.not_to raise_error
      end

      it "rejects when the profile is none of the configured types" do
        stub_session_and_account(profiles: [build_profile("StrangerProfile")])

        expect { controller.verify_audience! }
          .to raise_error(StandardId::InvalidAudienceProfileError) do |error|
            expect(error.expected_profile_types).to eq(["PlatformProfile", "DeviceUserProfile"])
            expect(error.actual_profile_type).to eq("StrangerProfile")
          end
      end
    end

    context "when audience_profile_resolver is configured" do
      let(:token_audience) { "admin_kit" }

      before do
        allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
          "admin_kit" => "PlatformProfile"
        )
      end

      it "uses the custom resolver" do
        custom_profile = double("Profile", profileable_type: "PlatformProfile", active?: true)
        captured = {}
        resolver = ->(account:, audience:, profile_types:) do
          captured[:account] = account
          captured[:audience] = audience
          captured[:profile_types] = profile_types
          custom_profile
        end
        allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(resolver)
        stub_session_and_account(profiles: [])

        expect { controller.verify_audience! }.not_to raise_error
        expect(captured[:audience]).to eq("admin_kit")
        expect(captured[:profile_types]).to eq(["PlatformProfile"])
        expect(captured[:account]).to eq(account)
      end

      it "raises when the resolver returns nil" do
        allow(StandardId.config.oauth).to receive(:audience_profile_resolver)
          .and_return(->(**) { nil })
        stub_session_and_account(profiles: [build_profile("PlatformProfile")])

        expect { controller.verify_audience! }
          .to raise_error(StandardId::InvalidAudienceProfileError)
      end
    end

    context "when multiple active profiles of the expected type exist" do
      let(:token_audience) { "admin_kit" }

      before do
        allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
          "admin_kit" => "PlatformProfile"
        )
      end

      it "prefers an active? profile" do
        inactive = build_profile("PlatformProfile", active: false)
        active = build_profile("PlatformProfile", active: true)
        stub_session_and_account(profiles: [inactive, active])

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
      expect(json_body[:error_description]).to eq(
        "The access token audience is not permitted for this resource"
      )
      expect(json_body[:error_description]).not_to include("admin")
      expect(response_headers["WWW-Authenticate"]).to eq(
        'Bearer error="insufficient_scope", error_description="The access token audience is not permitted for this resource"'
      )
    end

    it "also handles InvalidAudienceProfileError as a 403 insufficient_scope without leaking profile types" do
      error = StandardId::InvalidAudienceProfileError.new(
        audience: "admin_kit",
        expected_profile_types: "PlatformProfile",
        actual_profile_type: "DeviceUserProfile"
      )

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
      expect(json_body[:error_description]).to eq(
        "The access token audience is not permitted for this resource"
      )
      # Internal profile-type names and raw aud values must not leak to the client.
      expect(json_body[:error_description]).not_to include("admin_kit")
      expect(json_body[:error_description]).not_to include("PlatformProfile")
      expect(json_body[:error_description]).not_to include("DeviceUserProfile")
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
