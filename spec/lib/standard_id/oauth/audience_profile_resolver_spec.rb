require "rails_helper"

RSpec.describe StandardId::Oauth::AudienceProfileResolver do
  let(:account) { double("Account") }

  before do
    allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({})
    allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(nil)
  end

  def profile(type, active: true)
    double("Profile", profileable_type: type, active?: active)
  end

  describe ".profile_types_for" do
    it "returns [] when no mapping is configured" do
      expect(described_class.profile_types_for("anything")).to eq([])
    end

    it "returns a single-element array for a String mapping" do
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
        "admin_kit" => "PlatformProfile"
      )
      expect(described_class.profile_types_for("admin_kit")).to eq(["PlatformProfile"])
    end

    it "returns all entries for an Array mapping" do
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
        "harness" => ["PlatformProfile", "DeviceUserProfile"]
      )
      expect(described_class.profile_types_for("harness")).to eq(["PlatformProfile", "DeviceUserProfile"])
    end

    it "treats symbol keys equivalently to string keys" do
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
        admin_kit: "PlatformProfile"
      )
      expect(described_class.profile_types_for("admin_kit")).to eq(["PlatformProfile"])
    end

    it "returns [] for blank audience" do
      expect(described_class.profile_types_for(nil)).to eq([])
      expect(described_class.profile_types_for("")).to eq([])
    end
  end

  describe ".configured_for?" do
    it "is false when no mapping exists" do
      expect(described_class.configured_for?("admin_kit")).to be(false)
    end

    it "is true when a mapping exists" do
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
        "admin_kit" => "PlatformProfile"
      )
      expect(described_class.configured_for?("admin_kit")).to be(true)
    end
  end

  describe ".call" do
    before do
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return(
        "admin_kit" => "PlatformProfile",
        "harness" => ["PlatformProfile", "DeviceUserProfile"]
      )
    end

    it "returns nil when audience is nil" do
      allow(account).to receive(:profiles).and_return([])
      expect(described_class.call(account: account, audience: nil)).to be_nil
    end

    it "returns nil when account is nil" do
      expect(described_class.call(account: nil, audience: "admin_kit")).to be_nil
    end

    it "returns nil when audience is unconfigured" do
      allow(account).to receive(:profiles).and_return([profile("PlatformProfile")])
      expect(described_class.call(account: account, audience: "unknown")).to be_nil
    end

    it "returns the matching profile" do
      match = profile("PlatformProfile")
      allow(account).to receive(:profiles).and_return([profile("DeviceUserProfile"), match])
      expect(described_class.call(account: account, audience: "admin_kit")).to eq(match)
    end

    it "prefers active? matching profiles over inactive ones" do
      inactive = profile("PlatformProfile", active: false)
      active = profile("PlatformProfile", active: true)
      allow(account).to receive(:profiles).and_return([inactive, active])
      expect(described_class.call(account: account, audience: "admin_kit")).to eq(active)
    end

    it "supports multi-type audience mappings" do
      match = profile("DeviceUserProfile")
      allow(account).to receive(:profiles).and_return([match])
      expect(described_class.call(account: account, audience: "harness")).to eq(match)
    end

    it "falls back to the first match when active? is not available" do
      profile_without_active = double("Profile", profileable_type: "PlatformProfile")
      allow(account).to receive(:profiles).and_return([profile_without_active])
      expect(described_class.call(account: account, audience: "admin_kit")).to eq(profile_without_active)
    end

    context "when audience_profile_resolver is configured" do
      it "delegates to the custom resolver" do
        custom = double("Profile")
        resolver = ->(account:, audience:, profile_types:) { custom }
        allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(resolver)

        expect(described_class.call(account: account, audience: "admin_kit")).to eq(custom)
      end

      it "filters keyword args so resolvers can omit unused ones" do
        custom = double("Profile")
        captured = {}
        resolver = ->(account:, audience:) do
          captured[:account] = account
          captured[:audience] = audience
          custom
        end
        allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(resolver)

        expect(described_class.call(account: account, audience: "admin_kit")).to eq(custom)
        expect(captured[:audience]).to eq("admin_kit")
      end
    end
  end
end
