require "rails_helper"

RSpec.describe StandardId::Oauth::ClientRegistration do
  let(:owner) do
    Account.create!(name: "DCR Owner", email: "dcr-svc-#{SecureRandom.hex(4)}@example.com")
  end

  before do
    allow(StandardId.config.oauth).to receive(:dynamic_registration_owner).and_return(-> { owner })
  end

  describe ".call" do
    it "creates a public client with forced PKCE/S256 and consent defaults" do
      result = described_class.call(
        client_name: "Public Client",
        redirect_uris: ["https://app.example.com/cb"]
      )

      client = result.value
      expect(result.success?).to be(true)
      expect(client).to be_persisted
      expect(client.client_type).to eq("public")
      expect(client.require_pkce).to be(true)
      expect(client.code_challenge_methods_array).to eq(["S256"])
      expect(client.require_consent).to be(true)
      expect(client.scopes).to eq("openid profile email")
      expect(client.owner).to eq(owner)
      expect(result.client_secret).to be_nil
    end

    it "creates a confidential client with a one-time secret" do
      result = described_class.call(
        redirect_uris: ["https://server.example.com/cb"],
        token_endpoint_auth_method: "client_secret_post"
      )

      expect(result.value.client_type).to eq("confidential")
      expect(result.client_secret).to be_present
      expect(result.value.primary_client_secret).to be_present
    end

    it "accepts a space-delimited redirect_uris string" do
      result = described_class.call(
        redirect_uris: "https://a.example.com/cb https://b.example.com/cb"
      )

      expect(result.value.redirect_uris_array).to contain_exactly(
        "https://a.example.com/cb", "https://b.example.com/cb"
      )
    end

    it "raises InvalidRedirectUriError when redirect_uris is missing" do
      expect do
        described_class.call(client_name: "No Redirect")
      end.to raise_error(StandardId::InvalidRedirectUriError)
    end

    it "raises InvalidRedirectUriError when a redirect_uri is invalid" do
      expect do
        described_class.call(redirect_uris: ["not-a-uri"])
      end.to raise_error(StandardId::InvalidRedirectUriError)
    end

    it "raises InvalidClientMetadataError for a disallowed grant_type" do
      expect do
        described_class.call(
          redirect_uris: ["https://app.example.com/cb"],
          grant_types: ["client_credentials"]
        )
      end.to raise_error(StandardId::InvalidClientMetadataError, /client_credentials/)
    end

    it "raises InvalidClientMetadataError for a disallowed response_type" do
      expect do
        described_class.call(
          redirect_uris: ["https://app.example.com/cb"],
          response_types: ["token"]
        )
      end.to raise_error(StandardId::InvalidClientMetadataError, /token/)
    end

    it "raises InvalidClientMetadataError for an unsupported auth method" do
      expect do
        described_class.call(
          redirect_uris: ["https://app.example.com/cb"],
          token_endpoint_auth_method: "private_key_jwt"
        )
      end.to raise_error(StandardId::InvalidClientMetadataError, /private_key_jwt/)
    end

    context "with oauth.dynamic_registration_default_auth_method" do
      it "defaults to a public client when the config is the default 'none' and no method is given" do
        result = described_class.call(redirect_uris: ["https://app.example.com/cb"])

        expect(result.value.client_type).to eq("public")
        expect(result.token_endpoint_auth_method).to eq("none")
        expect(result.client_secret).to be_nil
      end

      it "defaults to a confidential client when the config is set to a secret-bearing method" do
        allow(StandardId.config.oauth)
          .to receive(:dynamic_registration_default_auth_method)
          .and_return("client_secret_basic")

        result = described_class.call(redirect_uris: ["https://app.example.com/cb"])

        expect(result.value.client_type).to eq("confidential")
        expect(result.token_endpoint_auth_method).to eq("client_secret_basic")
        expect(result.client_secret).to be_present
      end

      it "still honours an explicit request method over the config default" do
        allow(StandardId.config.oauth)
          .to receive(:dynamic_registration_default_auth_method)
          .and_return("client_secret_basic")

        result = described_class.call(
          redirect_uris: ["https://app.example.com/cb"],
          token_endpoint_auth_method: "none"
        )

        expect(result.value.client_type).to eq("public")
        expect(result.token_endpoint_auth_method).to eq("none")
      end

      it "raises ConfigurationError when the config holds an unsupported value" do
        allow(StandardId.config.oauth)
          .to receive(:dynamic_registration_default_auth_method)
          .and_return("private_key_jwt")

        expect do
          described_class.call(redirect_uris: ["https://app.example.com/cb"])
        end.to raise_error(StandardId::ConfigurationError, /dynamic_registration_default_auth_method/)
      end
    end

    context "when the owner resolver is nil" do
      before do
        allow(StandardId.config.oauth).to receive(:dynamic_registration_owner).and_return(nil)
      end

      it "raises a clear ConfigurationError" do
        expect do
          described_class.call(redirect_uris: ["https://app.example.com/cb"])
        end.to raise_error(StandardId::ConfigurationError, /dynamic_registration_owner/)
      end
    end

    context "when the owner resolver returns nil" do
      before do
        allow(StandardId.config.oauth).to receive(:dynamic_registration_owner).and_return(-> { })
      end

      it "raises a clear ConfigurationError" do
        expect do
          described_class.call(redirect_uris: ["https://app.example.com/cb"])
        end.to raise_error(StandardId::ConfigurationError, /resolved to nil/)
      end
    end
  end
end
