require "rails_helper"

RSpec.describe StandardId::ScopeConfig do
  describe "#initialize" do
    it "sets all attributes from config hash" do
      config = described_class.new(:borrower, {
        profile_type: "BorrowerProfile",
        after_sign_in_path: "/borrower/dashboard",
        no_profile_message: "No borrower account found.",
        label: "Borrower Login",
        allow_registration: false
      })

      expect(config.name).to eq(:borrower)
      expect(config.profile_type).to eq("BorrowerProfile")
      expect(config.after_sign_in_path).to eq("/borrower/dashboard")
      expect(config.no_profile_message).to eq("No borrower account found.")
      expect(config.label).to eq("Borrower Login")
      expect(config.allow_registration).to eq(false)
    end

    it "applies defaults for missing keys" do
      config = described_class.new(:admin, {})

      expect(config.name).to eq(:admin)
      expect(config.profile_type).to be_nil
      expect(config.after_sign_in_path).to be_nil
      expect(config.no_profile_message).to eq("Access denied. No matching profile found.")
      expect(config.label).to eq("Admin")
      expect(config.allow_registration).to eq(true)
    end

    it "converts name to symbol" do
      config = described_class.new("borrower", {})
      expect(config.name).to eq(:borrower)
    end

    it "defaults allow_registration to true when not specified" do
      config = described_class.new(:member, { profile_type: "MemberProfile" })
      expect(config.allow_registration).to eq(true)
    end
  end

  describe "#requires_profile?" do
    it "returns true when profile_type is present" do
      config = described_class.new(:borrower, { profile_type: "BorrowerProfile" })
      expect(config.requires_profile?).to eq(true)
    end

    it "returns false when profile_type is nil" do
      config = described_class.new(:public, {})
      expect(config.requires_profile?).to eq(false)
    end
  end
end
