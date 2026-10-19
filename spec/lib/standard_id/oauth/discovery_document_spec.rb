require "rails_helper"

RSpec.describe StandardId::Oauth::DiscoveryDocument do
  describe ".build" do
    let(:doc) { described_class.build("https://auth.example.com") }

    it "derives endpoints from the issuer" do
      expect(doc[:issuer]).to eq("https://auth.example.com")
      expect(doc[:authorization_endpoint]).to eq("https://auth.example.com/authorize")
      expect(doc[:token_endpoint]).to eq("https://auth.example.com/oauth/token")
    end

    it "strips a trailing slash from the issuer when building endpoints" do
      doc = described_class.build("https://auth.example.com/")
      expect(doc[:token_endpoint]).to eq("https://auth.example.com/oauth/token")
    end

    it "always advertises PKCE S256" do
      expect(doc[:code_challenge_methods_supported]).to eq(%w[S256])
    end

    it "advertises every implemented grant by default" do
      expect(doc[:grant_types_supported]).to eq(%w[authorization_code refresh_token client_credentials])
    end

    it "drops grants listed in oauth.disabled_grant_types" do
      allow(StandardId.config.oauth).to receive(:disabled_grant_types).and_return(%w[client_credentials password])

      expect(doc[:grant_types_supported]).to eq(%w[authorization_code refresh_token])
    end

    it "omits registration_endpoint by default (DCR is Phase 2)" do
      expect(doc).not_to have_key(:registration_endpoint)
    end

    it "emits registration_endpoint only when registration is enabled (seam for Phase 2)" do
      doc = described_class.build("https://auth.example.com", registration_enabled: true)
      expect(doc[:registration_endpoint]).to eq("https://auth.example.com/oauth/register")
    end
  end
end
