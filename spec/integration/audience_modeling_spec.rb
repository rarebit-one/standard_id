require "rails_helper"

# End-to-end style coverage of the "three audiences, two profile types"
# pattern seen in sidekick-web. This exercises:
#
#   - AudienceVerification enforcing audience_profile_types
#   - Audience-aware claim_resolvers
#
# Both without the host app needing its own JwtAudienceVerification concern
# or custom ClaimResolver service.
RSpec.describe "audience modeling (integration)" do
  it "DELIBERATELY FAILS to verify the test aggregator gates merges (this PR will be closed without merging)" do
    expect(true).to eq(false)
  end

  let(:account) { double("AccountLike", id: 42, email: "alice@example.com", profiles: []) }
  let(:platform_profile) { double("Profile", profileable_type: "PlatformProfile", active?: true) }
  let(:device_user_profile) { double("Profile", profileable_type: "DeviceUserProfile", active?: true) }

  before do
    allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
      "admin_kit"     => "PlatformProfile",
      "companion_kit" => "DeviceUserProfile",
      "harness"       => "PlatformProfile"
    )
    allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(nil)
  end

  describe "AudienceVerification with audience_profile_types" do
    let(:controller_class) do
      Class.new(ActionController::API) do
        include StandardId::ApiAuthentication
        include StandardId::AudienceVerification
        verify_audience "admin_kit", "companion_kit", "harness"

        public :verify_audience!
      end
    end

    let(:controller) { controller_class.new }

    def stub_session(aud:, profiles:)
      session = StandardId::JwtService.session_class.new(
        account_id: account.id,
        scopes: [],
        grant_type: "authorization_code",
        aud: aud
      )
      manager = instance_double(StandardId::Api::SessionManager,
        current_session: session,
        current_account: account)
      allow(controller).to receive(:session_manager).and_return(manager)
      allow(account).to receive(:profiles).and_return(profiles)
    end

    it "admin_kit + PlatformProfile is permitted" do
      stub_session(aud: "admin_kit", profiles: [platform_profile])
      expect { controller.verify_audience! }.not_to raise_error
    end

    it "admin_kit + only DeviceUserProfile is rejected" do
      stub_session(aud: "admin_kit", profiles: [device_user_profile])
      expect { controller.verify_audience! }
        .to raise_error(StandardId::InvalidAudienceProfileError)
    end

    it "companion_kit + DeviceUserProfile is permitted" do
      stub_session(aud: "companion_kit", profiles: [device_user_profile])
      expect { controller.verify_audience! }.not_to raise_error
    end

    it "companion_kit + only PlatformProfile is rejected" do
      stub_session(aud: "companion_kit", profiles: [platform_profile])
      expect { controller.verify_audience! }
        .to raise_error(StandardId::InvalidAudienceProfileError) do |e|
          expect(e.audience).to eq("companion_kit")
          expect(e.expected_profile_types).to eq(["DeviceUserProfile"])
        end
    end

    it "harness + PlatformProfile is permitted (shared with admin_kit)" do
      stub_session(aud: "harness", profiles: [platform_profile])
      expect { controller.verify_audience! }.not_to raise_error
    end

    it "harness + DeviceUserProfile only is rejected" do
      stub_session(aud: "harness", profiles: [device_user_profile])
      expect { controller.verify_audience! }
        .to raise_error(StandardId::InvalidAudienceProfileError)
    end

    it "accounts with both profiles satisfy any of the three audiences" do
      %w[admin_kit companion_kit harness].each do |aud|
        stub_session(aud: aud, profiles: [platform_profile, device_user_profile])
        expect { controller.verify_audience! }.not_to raise_error, "failed for aud=#{aud}"
      end
    end
  end

  describe "audience-aware claim_resolvers" do
    # Simulates sidekick's ClaimResolver: only harness emits device_profile_gid.
    let(:resolver_service) do
      Class.new do
        def initialize(audience:, account:)
          @audience = audience
          @account = account
        end

        def call_device_profile_gid
          return nil unless @audience == "harness"
          "gid://sidekick/DeviceUserProfile/#{@account.id}"
        end
      end
    end

    let(:claim_resolvers) do
      service_klass = resolver_service
      {
        device_profile_gid: ->(account:, audience:) {
          service_klass.new(audience: audience, account: account).call_device_profile_gid
        },
        email: ->(account:) { account.email }
      }
    end

    it "invokes resolvers with audience: when they accept it" do
      captured = {}
      resolvers = {
        gid: ->(account:, audience:) {
          captured[:audience] = audience
          "gid-#{audience}"
        }
      }

      filter = StandardId::Utils::CallableParameterFilter.filter(
        resolvers[:gid],
        { account: account, audience: "admin_kit" }
      )
      result = resolvers[:gid].call(**filter)

      expect(captured[:audience]).to eq("admin_kit")
      expect(result).to eq("gid-admin_kit")
    end

    it "resolves device_profile_gid only for the harness audience" do
      harness_filter = StandardId::Utils::CallableParameterFilter.filter(
        claim_resolvers[:device_profile_gid],
        { account: account, audience: "harness" }
      )
      admin_filter = StandardId::Utils::CallableParameterFilter.filter(
        claim_resolvers[:device_profile_gid],
        { account: account, audience: "admin_kit" }
      )

      expect(claim_resolvers[:device_profile_gid].call(**harness_filter))
        .to eq("gid://sidekick/DeviceUserProfile/#{account.id}")
      expect(claim_resolvers[:device_profile_gid].call(**admin_filter))
        .to be_nil
    end

    it "keeps audience-agnostic resolvers working" do
      filter = StandardId::Utils::CallableParameterFilter.filter(
        claim_resolvers[:email],
        { account: account, audience: "admin_kit" }
      )
      expect(claim_resolvers[:email].call(**filter)).to eq(account.email)
    end
  end
end
