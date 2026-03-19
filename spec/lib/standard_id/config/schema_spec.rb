require "rails_helper"

RSpec.describe "StandardId config schema" do
  describe "passwordless scope defaults" do
    it "defaults bypass_code to nil" do
      expect(StandardId.config.passwordless.bypass_code).to be_nil
    end
  end
end
