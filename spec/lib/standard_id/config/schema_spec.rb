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

  describe "passwordless.delivery" do
    it "defaults to :custom" do
      expect(StandardId.config.passwordless.delivery).to eq(:custom)
    end
  end

  describe "passwordless.mailer_from" do
    it "defaults to noreply@example.com" do
      expect(StandardId.config.passwordless.mailer_from).to eq("noreply@example.com")
    end
  end

  describe "passwordless.mailer_subject" do
    it "defaults to 'Your sign-in code'" do
      expect(StandardId.config.passwordless.mailer_subject).to eq("Your sign-in code")
    end
  end
end
