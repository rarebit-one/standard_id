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

  describe "redirect URI rules for self-registered clients" do
    it "refuses a non-loopback http redirect_uri with invalid_redirect_uri" do
      expect { described_class.call(redirect_uris: ["http://example.com/cb"]) }
        .to raise_error(StandardId::InvalidRedirectUriError, /https/)
    end

    it "accepts https and loopback http" do
      client = described_class.call(redirect_uris: ["https://app.example.com/cb", "http://127.0.0.1:8080/cb", "http://localhost/cb"]).client
      expect(client.redirect_uris_array.size).to eq(3)
    end

    it "caps the list" do
      uris = (1..11).map { |i| "https://app.example.com/cb#{i}" }
      expect { described_class.call(redirect_uris: uris) }
        .to raise_error(StandardId::InvalidRedirectUriError, /more than 10/)
    end

    it "does not leave the owner behind when the client is refused" do
      created = 0
      allow(StandardId.config.oauth).to receive(:dynamic_registration_owner).and_return(-> {
        created += 1
        Account.create!(name: "Per-registration owner #{created}", email: "owner-#{SecureRandom.hex(4)}@example.com")
      })

      expect { described_class.call(redirect_uris: []) }.to raise_error(StandardId::InvalidRedirectUriError)
      expect(Account.where("name LIKE 'Per-registration owner%'")).to be_empty
      expect(created).to eq(1)
    end
  end

  describe "pinned attributes (oauth.dynamic_registration_attributes)" do
    def pin(value)
      allow(StandardId.config.oauth).to receive(:dynamic_registration_attributes).and_return(value)
    end

    it "applies scopes, metadata, lifetimes, consent and description, ignoring the requested scope" do
      pin(scopes: %w[mcp mcp:read], metadata: { "audience" => "mcp", dcr: true }, access_token_lifetime: 900,
        authorization_code_lifetime: 120, require_consent: false, description: "MCP connector")
      client = described_class.call(redirect_uris: ["https://app.example.com/cb"], scope: "openid admin").value

      expect(client.scopes).to eq("mcp mcp:read")
      expect(client.metadata).to eq("audience" => "mcp", "dcr" => true)
      expect(client.access_token_lifetime).to eq(900)
      expect(client.authorization_code_lifetime).to eq(120)
      expect(client.require_consent).to be(false)
      expect(client.description).to eq("MCP connector")
    end

    it "gives a pinned audience its audience_scopes vocabulary when scopes are not pinned" do
      pin(metadata: { "audience" => "mcp" })
      allow(StandardId.config.oauth).to receive(:audience_scopes).and_return("mcp" => %w[mcp mcp:read])
      client = described_class.call(redirect_uris: ["https://app.example.com/cb"], scope: "openid").value
      expect(client.scopes).to eq("mcp mcp:read")
    end

    it "accepts a callable receiving the document" do
      pin(->(metadata:) { { description: "for #{metadata[:client_name]}" } })
      client = described_class.call(client_name: "Acme", redirect_uris: ["https://app.example.com/cb"]).value
      expect(client.description).to eq("for Acme")
    end

    it "raises ConfigurationError for an unknown key" do
      pin(client_type: "confidential")
      expect { described_class.call(redirect_uris: ["https://app.example.com/cb"]) }
        .to raise_error(StandardId::ConfigurationError, /unknown key/)
    end
  end

  describe "auth-method allowlist (oauth.dynamic_registration_auth_methods)" do
    it "refuses a method outside the allowlist with invalid_client_metadata" do
      allow(StandardId.config.oauth).to receive(:dynamic_registration_auth_methods).and_return(%w[none])
      expect {
        described_class.call(redirect_uris: ["https://app.example.com/cb"], token_endpoint_auth_method: "client_secret_basic")
      }.to raise_error(StandardId::InvalidClientMetadataError, /client_secret_basic/)
    end
  end

  describe "registration access token (RFC 7592)" do
    it "issues a one-time token and stores only its digest" do
      result = described_class.call(redirect_uris: ["https://app.example.com/cb"])
      token = result.registration_access_token
      client = result.client

      expect(token).to be_present
      expect(client.registration_access_token_digest).to eq(StandardId::ClientApplication.digest_registration_access_token(token))
      expect(client).to be_dynamically_registered
      expect(client.authenticate_registration_access_token(token)).to be(true)
      expect(client.authenticate_registration_access_token("nope")).to be(false)
      expect(StandardId::ClientApplication.dynamically_registered).to include(client)
    end

    it "hands the owner resolver the document when it asks for it" do
      seen = nil
      allow(StandardId.config.oauth).to receive(:dynamic_registration_owner).and_return(->(metadata:) { seen = metadata; owner })
      described_class.call(client_name: "Acme", redirect_uris: ["https://app.example.com/cb"])
      expect(seen[:client_name]).to eq("Acme")
    end
  end

  describe ".update (RFC 7592 §2.2)" do
    let(:client) do
      allow(StandardId.config.oauth).to receive(:dynamic_registration_attributes).and_return(scopes: %w[mcp])
      described_class.call(client_name: "Before", redirect_uris: ["https://app.example.com/cb"]).client
    end

    it "changes the client-shaped members and keeps the pinned ones" do
      result = described_class.update(client, client_id: client.client_id, client_name: "After",
        redirect_uris: ["https://app.example.com/cb2"], grant_types: %w[authorization_code refresh_token], scope: "openid admin")
      client.reload
      expect(client.name).to eq("After")
      expect(client.redirect_uris_array).to eq(["https://app.example.com/cb2"])
      expect(client.grant_types_array).to eq(%w[authorization_code refresh_token])
      expect(client.scopes).to eq("mcp")
      expect(result.registration_access_token).to be_nil
    end

    it "rejects a client_id that names another client, or a change of client type" do
      expect { described_class.update(client, client_id: "other", redirect_uris: ["https://app.example.com/cb"]) }
        .to raise_error(StandardId::InvalidClientMetadataError, /client_id/)
      expect { described_class.update(client, redirect_uris: ["https://app.example.com/cb"], token_endpoint_auth_method: "client_secret_post") }
        .to raise_error(StandardId::InvalidClientMetadataError, /public and confidential/)
    end

    it "holds an update to the registration rules" do
      expect { described_class.update(client, redirect_uris: ["https://app.example.com/cb"], grant_types: %w[client_credentials]) }
        .to raise_error(StandardId::InvalidClientMetadataError, /client_credentials/)
    end
  end

  describe ".deregister (RFC 7592 §2.3)" do
    it "deactivates the client, revokes its refresh tokens and removes its unused codes" do
      client = described_class.call(redirect_uris: ["https://app.example.com/cb"]).client
      token = StandardId::RefreshToken.create!(account: owner, client_application: client,
        token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid), expires_at: 30.days.from_now)
      code = StandardId::AuthorizationCode.issue!(plaintext_code: SecureRandom.hex(20), client_id: client.client_id,
        redirect_uri: "https://app.example.com/cb", account: owner)

      described_class.deregister(client)

      expect(client.reload).not_to be_active
      expect(token.reload.revoked_at).to be_present
      expect(StandardId::AuthorizationCode.exists?(code.id)).to be(false)
    end
  end
end
