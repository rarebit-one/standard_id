require "rails_helper"

RSpec.describe "StandardId config schema" do
  describe "passwordless scope defaults" do
    it "defaults bypass_code to nil" do
      expect(StandardId.config.passwordless.bypass_code).to be_nil
    end
  end

  describe "passwordless.bypass_code" do
    it "round-trips a non-nil value" do
      allow(StandardId.config.passwordless).to receive(:bypass_code).and_return("test-code")
      expect(StandardId.config.passwordless.bypass_code).to eq("test-code")
    end
  end
end
