require "rails_helper"

RSpec.describe "StandardId Web Mechanism Config" do
  describe "defaults" do
    it "enables password_login by default" do
      expect(StandardId.config.web.password_login).to eq(true)
    end

    it "enables signup by default" do
      expect(StandardId.config.web.signup).to eq(true)
    end

    it "disables passwordless_login by default" do
      expect(StandardId.config.web.passwordless_login).to eq(false)
    end

    it "enables social_login by default" do
      expect(StandardId.config.web.social_login).to eq(true)
    end

    it "enables password_reset by default" do
      expect(StandardId.config.web.password_reset).to eq(true)
    end

    it "enables email_verification by default" do
      expect(StandardId.config.web.email_verification).to eq(true)
    end

    it "enables phone_verification by default" do
      expect(StandardId.config.web.phone_verification).to eq(true)
    end

    it "enables sessions_management by default" do
      expect(StandardId.config.web.sessions_management).to eq(true)
    end
  end

  describe "configuration" do
    it "allows setting values via the web scope" do
      original = StandardId.config.web.signup
      StandardId.config.web.signup = false
      expect(StandardId.config.web.signup).to eq(false)
    ensure
      StandardId.config.web.signup = original
    end
  end
end
