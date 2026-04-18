require "rails_helper"

RSpec.describe StandardId::ScopeConfig do
  # Silence the :profile_type deprecation warning in default describe blocks —
  # the dedicated "deprecation warning" describe below asserts it instead.
  let(:silence_deprecations) do
    ->(&block) { ActiveSupport::Deprecation.new("2.0", "StandardId").silence { block.call } }
  end

  describe "#initialize" do
    it "sets all attributes from config hash (singular profile_type, back-compat)" do
      config = nil
      silence_deprecations.call do
        config = described_class.new(:borrower, {
          profile_type: "BorrowerProfile",
          after_sign_in_path: "/borrower/dashboard",
          no_profile_message: "No borrower account found.",
          label: "Borrower Login",
          allow_registration: false
        })
      end

      expect(config.name).to eq(:borrower)
      expect(config.profile_type).to eq("BorrowerProfile")
      expect(config.profile_types).to eq(["BorrowerProfile"])
      expect(config.after_sign_in_path).to eq("/borrower/dashboard")
      expect(config.no_profile_message).to eq("No borrower account found.")
      expect(config.label).to eq("Borrower Login")
      expect(config.allow_registration).to eq(false)
    end

    it "accepts :profile_types as an array and exposes both plural and (first) singular" do
      config = described_class.new(:lender, {
        profile_types: ["OrganisationProfile", "BorrowerProfile"],
        after_sign_in_path: "/lender/dashboard"
      })

      expect(config.profile_types).to eq(["OrganisationProfile", "BorrowerProfile"])
      expect(config.profile_type).to eq("OrganisationProfile")
      expect(config.requires_profile?).to eq(true)
    end

    it "applies defaults for missing keys" do
      config = described_class.new(:admin, {})

      expect(config.name).to eq(:admin)
      expect(config.profile_type).to be_nil
      expect(config.profile_types).to eq([])
      expect(config.after_sign_in_path).to be_nil
      expect(config.no_profile_message).to eq("Access denied. No matching profile found.")
      expect(config.label).to eq("Admin")
      expect(config.allow_registration).to eq(true)
      expect(config.authorizer).to be_nil
      expect(config.authorizer?).to eq(false)
    end

    it "converts name to symbol" do
      config = described_class.new("borrower", {})
      expect(config.name).to eq(:borrower)
    end

    it "defaults allow_registration to true when not specified" do
      config = described_class.new(:member, { profile_types: ["MemberProfile"] })
      expect(config.allow_registration).to eq(true)
    end

    it "raises when both :profile_type and :profile_types are provided" do
      expect {
        described_class.new(:borrower, {
          profile_type: "BorrowerProfile",
          profile_types: ["BorrowerProfile"]
        })
      }.to raise_error(ArgumentError, /both :profile_type and :profile_types/)
    end

    it "uses a plural-aware default no_profile_message when multiple types are configured" do
      config = described_class.new(:lender, {
        profile_types: ["OrganisationProfile", "BorrowerProfile"]
      })

      expect(config.no_profile_message).to include("OrganisationProfile")
      expect(config.no_profile_message).to include("BorrowerProfile")
    end

    it "captures the authorizer callable" do
      authorizer = ->(account:, profile:, scope:) { true }
      config = described_class.new(:lender, {
        profile_types: ["OrganisationProfile"],
        authorizer: authorizer
      })

      expect(config.authorizer).to eq(authorizer)
      expect(config.authorizer?).to eq(true)
    end
  end

  describe "deprecation warning for :profile_type (singular)" do
    it "fires an ActiveSupport::Deprecation warning when :profile_type is used" do
      expect(described_class::DEPRECATOR).to receive(:warn).with(/:profile_type is deprecated/)

      described_class.new(:borrower, { profile_type: "BorrowerProfile" })
    end

    it "does NOT warn when :profile_types (plural) is used" do
      expect(described_class::DEPRECATOR).not_to receive(:warn)

      described_class.new(:borrower, { profile_types: ["BorrowerProfile"] })
    end
  end

  describe "#requires_profile?" do
    it "returns true when profile_types is non-empty" do
      config = described_class.new(:borrower, { profile_types: ["BorrowerProfile"] })
      expect(config.requires_profile?).to eq(true)
    end

    it "returns false when profile_types is empty" do
      config = described_class.new(:public, {})
      expect(config.requires_profile?).to eq(false)
    end
  end

  describe "#accepts_profile_type?" do
    let(:config) { described_class.new(:lender, { profile_types: ["OrganisationProfile", "BorrowerProfile"] }) }

    it "returns true for a type in the list" do
      expect(config.accepts_profile_type?("BorrowerProfile")).to eq(true)
    end

    it "returns false for a type not in the list" do
      expect(config.accepts_profile_type?("AdminProfile")).to eq(false)
    end

    it "returns false for nil/blank" do
      expect(config.accepts_profile_type?(nil)).to eq(false)
      expect(config.accepts_profile_type?("")).to eq(false)
    end
  end
end
