require "rails_helper"

RSpec.describe StandardId::Config::Presets do
  # A fresh config from the real schema, so the global StandardId.config is
  # left alone.
  let(:config) { StandardId::ConfigSchema.build }

  describe "c.preset :inertia_web" do
    it "sets the Inertia web surface with no password sign-up, login or reset" do
      config.preset :inertia_web

      expect(config.use_inertia).to be(true)
      expect(config.alias_current_user).to be(true)
      expect(config.web.signup).to be(false)
      expect(config.web.password_login).to be(false)
      expect(config.web.password_reset).to be(false)
      expect(config.oauth.discovery_endpoint_base).to eq(:request)
    end

    it "leaves passwordless_login to the host" do
      expect { config.preset :inertia_web }.not_to(change { config.web.passwordless_login })
    end

    it "keeps a setting the host assigned before the preset" do
      config.web.signup = true
      config.oauth.discovery_endpoint_base = "https://auth.example.com/api"

      config.preset :inertia_web

      expect(config.web.signup).to be(true)
      expect(config.oauth.discovery_endpoint_base).to eq("https://auth.example.com/api")
      expect(config.web.password_login).to be(false)
    end

    it "lets an assignment after the preset win" do
      config.preset :inertia_web
      config.use_inertia = false

      expect(config.use_inertia).to be(false)
    end

    it "accepts the name as a String" do
      config.preset "inertia_web"

      expect(config.use_inertia).to be(true)
    end
  end

  it "rejects an unknown preset, listing the valid ones" do
    expect { config.preset :inertia }
      .to raise_error(ArgumentError, /Unknown StandardId config preset: :inertia\. Valid presets: :inertia_web/)
  end

  it "leaves the public defaults unchanged when no preset is applied" do
    expect(config.use_inertia).to be(false)
    expect(config.web.signup).to be(true)
    expect(config.oauth.discovery_endpoint_base).to be_nil
  end
end
