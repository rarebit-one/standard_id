require "rails_helper"

RSpec.describe StandardId::Oauth::TokenGrantFlow do
  describe "class configuration API (grant-specific)" do
    let(:flow_class) { Class.new(described_class) }

    it "includes :grant_type via extra_permitted_keys" do
      expect(flow_class.expected_params).to eq([])
      expect(flow_class.permitted_params).to eq([:grant_type])
    end

    it "merges :grant_type into permitted params along with subclass config" do
      flow_class.expect_params(:client_id)
      flow_class.permit_params(:scope)
      expect(flow_class.permitted_params).to match_array([:client_id, :scope, :grant_type])
    end
  end

  describe "instance API" do
    let(:request) { instance_double("ActionDispatch::Request") }

    it "exposes params and request readers from initialize" do
      params = { a: 1 }
      flow = described_class.new(params, request)
      expect(flow.params).to eq(params)
      expect(flow.request).to eq(request)
    end

    it "execute calls authenticate! then generate_token_response and returns its result" do
      flow_class = Class.new(described_class) do
        def authenticate!
          @authenticated = true
        end

        def generate_token_response
          raise "authenticate! not called" unless @authenticated
          { access_token: "token", token_type: "bearer" }
        end
      end

      flow = flow_class.new({}, request)
      result = flow.execute
      expect(result).to eq({ access_token: "token", token_type: "bearer" })
    end

    it "generates a token response with JWT and optional fields" do
      # Define a concrete flow to provide required abstract methods
      concrete = Class.new(described_class) do
        def authenticate!; end
        def subject_id; "sub-123"; end
        def client_id; "cid-abc"; end
        def token_scope; "read write"; end
        def grant_type; "password"; end
        def audience; params[:audience]; end
        def token_expiry; 30.minutes; end
        def supports_refresh_token?; true; end
        def generate_refresh_token; "rtoken"; end
      end

      params = { audience: "https://api" }
      flow = concrete.new(params, request)

      expect(StandardId::JwtService).to receive(:encode) do |payload, opts|
        expect(payload).to include(
          sub: "sub-123",
          client_id: "cid-abc",
          scope: "read write",
          grant_type: "password",
          aud: "https://api"
        )
        expect(opts).to include(expires_in: 30.minutes)
        "jwt-token"
      end

      result = flow.execute
      expect(result).to include(
        access_token: "jwt-token",
        token_type: "Bearer",
        expires_in: 30.minutes.to_i,
        scope: "read write",
        refresh_token: "rtoken"
      )
    end

    it "validates client secret via StandardId::ClientSecretCredential" do
      concrete = Class.new(described_class) do
        def authenticate!
          # call the private validator from within authenticate!
          validate_client_secret!("cid", "secret")
        end
      end

      creds_double = instance_double("StandardId::ClientSecretCredential", authenticate_client_secret: true)
      scope_double = double("scope", find_by: creds_double)
      allow(StandardId::ClientSecretCredential).to receive(:active).and_return(scope_double)

      # Stub JWT generation since execute will call generate_token_response afterwards
      allow_any_instance_of(concrete).to receive(:generate_token_response).and_return({ ok: true })

      flow = concrete.new({}, request)
      expect { flow.execute }.not_to raise_error
    end
  end

  describe "audience → profile binding (mint-time fail-closed)" do
    let(:request) { instance_double("ActionDispatch::Request") }

    # Build an account stub whose profile list is configurable per-test. The
    # token_account hook is overridden directly on the concrete class so
    # tests don't have to stub StandardId.account_class (which is global
    # state and would leak across examples).
    def build_flow(audience:, account:)
      concrete = Class.new(described_class) do
        attr_accessor :_test_account

        def authenticate!; end
        def subject_id; "sub-123"; end
        def client_id; "cid-abc"; end
        def token_scope; "read write"; end
        def grant_type; "password"; end
        def token_expiry; 30.minutes; end
        def supports_refresh_token?; false; end
        def maybe_persist_session_for_token!; end
        def token_account; @_test_account; end
      end
      flow = concrete.new({ audience: audience }, request)
      flow._test_account = account
      flow
    end

    def stub_audience_binding(mapping)
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(mapping)
      allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(nil)
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(mapping.keys.map(&:to_s))
    end

    def profile(type, id:, active: true)
      double("Profile", profileable_type: type, active?: active, id: id)
    end

    it "fails closed (NoBoundProfileError) when no matching profile exists" do
      stub_audience_binding("admin_kit" => "PlatformProfile")
      account = double("Account", profiles: [profile("DeviceUserProfile", id: 1)])
      flow = build_flow(audience: "admin_kit", account: account)

      # JWT should never be encoded — we fail before mint.
      expect(StandardId::JwtService).not_to receive(:encode)

      expect { flow.execute }.to raise_error(StandardId::NoBoundProfileError)
    end

    it "raised error is also an InvalidGrantError so OAuth error handlers catch it" do
      stub_audience_binding("admin_kit" => "PlatformProfile")
      account = double("Account", profiles: [])
      flow = build_flow(audience: "admin_kit", account: account)

      expect { flow.execute }.to raise_error(StandardId::InvalidGrantError)
    end

    it "fails closed (AmbiguousProfileError) when multiple active profiles match" do
      stub_audience_binding("admin_kit" => "PlatformProfile")
      account = double("Account", profiles: [
        profile("PlatformProfile", id: 10),
        profile("PlatformProfile", id: 11)
      ])
      flow = build_flow(audience: "admin_kit", account: account)

      expect(StandardId::JwtService).not_to receive(:encode)

      expect { flow.execute }.to raise_error(StandardId::AmbiguousProfileError) do |err|
        expect(err.profile_ids).to match_array([10, 11])
      end
    end

    it "succeeds when exactly one active matching profile exists" do
      stub_audience_binding("admin_kit" => "PlatformProfile")
      match = profile("PlatformProfile", id: 42)
      account = double("Account", profiles: [match], locked?: false, inactive?: false, id: 1)
      flow = build_flow(audience: "admin_kit", account: account)

      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      result = flow.execute
      expect(result[:access_token]).to eq("jwt-token")
    end

    it "is a no-op when the audience has no binding configured (back-compat)" do
      stub_audience_binding({}) # no bindings — pure allowed_audiences path
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return([])

      # locked? is needed by the AccountLocking subscriber wired to
      # OAUTH_TOKEN_ISSUING.
      account = double("Account", locked?: false, inactive?: false, id: 1)
      flow = build_flow(audience: "anything", account: account)

      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      expect { flow.execute }.not_to raise_error
    end

    it "rejects tokens that bind to multiple profile-bound audiences in one mint" do
      stub_audience_binding(
        "admin_kit" => "PlatformProfile",
        "harness" => "DeviceUserProfile"
      )
      account = double("Account") # never reaches resolver
      flow = build_flow(audience: ["admin_kit", "harness"], account: account)

      expect { flow.execute }.to raise_error(
        StandardId::InvalidGrantError,
        /multiple profile-bound audiences/i
      )
    end

    describe "OAUTH_TOKEN_ISSUED event enrichment" do
      it "includes profile_id, audience, jti, and requested_scopes" do
        stub_audience_binding("admin_kit" => "PlatformProfile")
        match = profile("PlatformProfile", id: 777)
        account = double("Account", profiles: [match], locked?: false, inactive?: false, id: 1)
        flow = build_flow(audience: "admin_kit", account: account)

        captured_jti = nil
        allow(StandardId::JwtService).to receive(:encode) do |payload, _opts|
          captured_jti = payload[:jti]
          "jwt-token"
        end

        captured_payload = nil
        allow(StandardId::Events).to receive(:publish).and_call_original
        expect(StandardId::Events).to receive(:publish).with(
          StandardId::Events::OAUTH_TOKEN_ISSUED, hash_including(:jti)
        ) do |_name, payload|
          captured_payload = payload
        end

        flow.execute

        expect(captured_payload[:profile_id]).to eq(777)
        expect(captured_payload[:audience]).to eq("admin_kit")
        expect(captured_payload[:jti]).to eq(captured_jti)
        expect(captured_payload[:jti]).to be_a(String)
        expect(captured_payload[:requested_scopes]).to match_array(["read", "write"])
        # And the previously-emitted fields are preserved
        expect(captured_payload).to include(
          grant_type: "password",
          client_id: "cid-abc",
          expires_in: 30.minutes
        )
      end

      it "emits profile_id=nil when the audience has no binding" do
        stub_audience_binding({})
        allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return([])

        account = double("Account", locked?: false, inactive?: false, id: 1)
        flow = build_flow(audience: nil, account: account)

        allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

        captured = nil
        allow(StandardId::Events).to receive(:publish).and_call_original
        expect(StandardId::Events).to receive(:publish)
          .with(StandardId::Events::OAUTH_TOKEN_ISSUED, hash_including(:profile_id)) do |_, payload|
            captured = payload
          end

        flow.execute

        expect(captured[:profile_id]).to be_nil
      end
    end
  end
end
