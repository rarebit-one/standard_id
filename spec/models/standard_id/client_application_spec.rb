require "rails_helper"

RSpec.describe StandardId::ClientApplication, type: :model do
  let(:account) { Account.create!(name: "Test Account", email: "test@example.com") }

  describe "associations" do
    it { should belong_to(:owner) }
    it { should have_many(:client_secret_credentials).dependent(:destroy) }
    it { should have_many(:authorization_codes).dependent(:destroy) }
  end

  describe "validations" do
    subject { described_class.new(owner: account, name: "Test Client", redirect_uris: "https://example.com/callback") }

    it { should validate_presence_of(:name) }
    it { should validate_length_of(:name).is_at_most(255) }
    it { should validate_length_of(:description).is_at_most(1000) }
    it { should validate_presence_of(:redirect_uris) }
    it { should validate_inclusion_of(:client_type).in_array(%w[confidential public]) }
    it { should validate_presence_of(:grant_types) }
    it { should validate_presence_of(:response_types) }
    it { should validate_presence_of(:scopes) }
    it { should validate_numericality_of(:access_token_lifetime).is_greater_than(0) }
    it { should validate_numericality_of(:refresh_token_lifetime).is_greater_than(0) }
    it { should validate_numericality_of(:authorization_code_lifetime).is_greater_than(0) }

    context "when require_pkce is true" do
      before { subject.require_pkce = true }
      it { should validate_presence_of(:code_challenge_methods) }
    end

    context "when require_pkce is false" do
      before { subject.require_pkce = false }
      it { should_not validate_presence_of(:code_challenge_methods) }
    end

    describe "public clients cannot opt out of PKCE" do
      it "rejects a public client that sets require_pkce: false" do
        client = described_class.new(
          owner: account,
          name: "Public Opt-Out",
          redirect_uris: "https://example.com/cb",
          client_type: "public",
          require_pkce: false
        )

        expect(client).not_to be_valid
        expect(client.errors[:require_pkce]).to include("public clients must have require_pkce enabled")
      end

      it "accepts a public client that keeps require_pkce enabled" do
        client = described_class.new(
          owner: account,
          name: "Public OK",
          redirect_uris: "https://example.com/cb",
          client_type: "public",
          require_pkce: true
        )

        expect(client).to be_valid
      end

      it "allows a confidential client to disable require_pkce" do
        client = described_class.new(
          owner: account,
          name: "Confidential Opt-Out",
          redirect_uris: "https://example.com/cb",
          client_type: "confidential",
          require_pkce: false,
          code_challenge_methods: nil
        )

        expect(client).to be_valid
      end
    end
  end

  describe "scopes" do
    let!(:active_client) { described_class.create!(owner: account, name: "Active", redirect_uris: "https://example.com") }
    let!(:inactive_client) { described_class.create!(owner: account, name: "Inactive", redirect_uris: "https://example.com", active: false) }
    let!(:confidential_client) { described_class.create!(owner: account, name: "Confidential", redirect_uris: "https://example.com", client_type: "confidential") }
    let!(:public_client) { described_class.create!(owner: account, name: "Public", redirect_uris: "https://example.com", client_type: "public") }

    describe ".active" do
      it "returns only active clients" do
        expect(described_class.active).to include(active_client, confidential_client, public_client)
        expect(described_class.active).not_to include(inactive_client)
      end
    end

    describe ".confidential" do
      it "returns only confidential clients" do
        expect(described_class.confidential).to include(confidential_client)
        expect(described_class.confidential).not_to include(public_client)
      end
    end

    describe ".public_clients" do
      it "returns only public clients" do
        expect(described_class.public_clients).to include(public_client)
        expect(described_class.public_clients).not_to include(confidential_client)
      end
    end

    describe ".for_owner" do
      let(:other_account) { Account.create!(name: "Other", email: "other@example.com") }
      let!(:other_client) { described_class.create!(owner: other_account, name: "Other Client", redirect_uris: "https://example.com") }

      it "returns clients for specific owner" do
        expect(described_class.for_owner(account)).to include(active_client, inactive_client, confidential_client, public_client)
        expect(described_class.for_owner(account)).not_to include(other_client)
      end
    end
  end

  describe "callbacks" do
    describe "before_create :generate_client_id" do
      it "generates a client_id when creating" do
        client = described_class.new(owner: account, name: "Test", redirect_uris: "https://example.com")
        expect(client.client_id).to be_nil
        client.save!
        expect(client.client_id).to be_present
        expect(client.client_id).to match(/\A[a-f0-9]{32}\z/)
      end

      it "does not override existing client_id" do
        custom_id = "custom_client_id"
        client = described_class.create!(owner: account, name: "Test", redirect_uris: "https://example.com", client_id: custom_id)
        expect(client.client_id).to eq(custom_id)
      end
    end

    describe "before_update :set_deactivated_at" do
      let(:client) { described_class.create!(owner: account, name: "Test", redirect_uris: "https://example.com") }

      it "sets deactivated_at when active becomes false" do
        expect(client.deactivated_at).to be_nil
        client.update!(active: false)
        expect(client.deactivated_at).to be_present
      end

      it "clears deactivated_at when active becomes true" do
        client.update!(active: false)
        expect(client.deactivated_at).to be_present

        # Use activate! method which properly handles the callback
        client.activate!
        expect(client.deactivated_at).to be_nil
      end
    end
  end

  describe "instance methods" do
    let(:client) do
      described_class.create!(
        owner: account,
        name: "Test Client",
        redirect_uris: "https://example.com/callback https://app.example.com/auth",
        scopes: "openid profile email read:users",
        grant_types: "authorization_code refresh_token client_credentials",
        response_types: "code token",
        code_challenge_methods: "S256 plain",
        require_pkce: true
      )
    end

    describe "#deactivate!" do
      it "sets active to false and deactivated_at" do
        client.deactivate!
        expect(client.active).to be false
        expect(client.deactivated_at).to be_present
      end
    end

    describe "#activate!" do
      before { client.deactivate! }

      it "sets active to true and clears deactivated_at" do
        client.activate!
        expect(client.active).to be true
        expect(client.deactivated_at).to be_nil
      end
    end

    describe "#active?" do
      it "returns true when active and not deactivated" do
        expect(client.active?).to be true
      end

      it "returns false when not active" do
        client.update!(active: false)
        expect(client.active?).to be false
      end

      it "returns false when deactivated_at is set" do
        client.update!(deactivated_at: Time.current)
        expect(client.active?).to be false
      end
    end

    describe "array helper methods" do
      describe "#redirect_uris_array" do
        it "splits redirect_uris into array" do
          expect(client.redirect_uris_array).to eq(["https://example.com/callback", "https://app.example.com/auth"])
        end
      end

      describe "#scopes_array" do
        it "splits scopes into array" do
          expect(client.scopes_array).to eq(["openid", "profile", "email", "read:users"])
        end
      end

      describe "#grant_types_array" do
        it "splits grant_types into array" do
          expect(client.grant_types_array).to eq(["authorization_code", "refresh_token", "client_credentials"])
        end
      end

      describe "#response_types_array" do
        it "splits response_types into array" do
          expect(client.response_types_array).to eq(["code", "token"])
        end
      end

      describe "#code_challenge_methods_array" do
        it "splits code_challenge_methods into array" do
          expect(client.code_challenge_methods_array).to eq(["S256", "plain"])
        end
      end
    end

    describe "support methods" do
      describe "#supports_grant_type?" do
        it "returns true for supported grant types" do
          expect(client.supports_grant_type?("authorization_code")).to be true
          expect(client.supports_grant_type?(:refresh_token)).to be true
        end

        it "returns false for unsupported grant types" do
          expect(client.supports_grant_type?("password")).to be false
        end
      end

      describe "#supports_response_type?" do
        it "returns true for supported response types" do
          expect(client.supports_response_type?("code")).to be true
          expect(client.supports_response_type?(:token)).to be true
        end

        it "returns false for unsupported response types" do
          expect(client.supports_response_type?("id_token")).to be false
        end
      end

      describe "#supports_pkce_method?" do
        it "returns true for supported PKCE methods when PKCE is required" do
          expect(client.supports_pkce_method?("S256")).to be true
          expect(client.supports_pkce_method?(:plain)).to be true
        end

        it "is case-insensitive (accepts lowercase variants)" do
          expect(client.supports_pkce_method?("s256")).to be true
          expect(client.supports_pkce_method?("PLAIN")).to be true
        end

        it "returns false for unsupported PKCE methods" do
          expect(client.supports_pkce_method?("invalid")).to be false
        end

        it "returns false when PKCE is not required" do
          client.update!(require_pkce: false)
          expect(client.supports_pkce_method?("S256")).to be false
        end
      end

      describe "#valid_redirect_uri?" do
        it "returns true for valid redirect URIs" do
          expect(client.valid_redirect_uri?("https://example.com/callback")).to be true
          expect(client.valid_redirect_uri?("https://app.example.com/auth")).to be true
        end

        it "returns false for invalid redirect URIs" do
          expect(client.valid_redirect_uri?("https://malicious.com")).to be false
        end

        it "allows the request URI to add a query string (OAuth spec allows the AS to append)" do
          # RFC 6749 §3.1.2: the authorization server MAY redirect with
          # additional query parameters. The registered URI is the canonical
          # base — equality is on scheme+host+port+path only.
          expect(client.valid_redirect_uri?("https://example.com/callback?attacker=1")).to be true
        end

        it "allows the request URI to include a fragment" do
          expect(client.valid_redirect_uri?("https://example.com/callback#section")).to be true
        end

        it "rejects request URIs with extra path segments (no prefix match)" do
          expect(client.valid_redirect_uri?("https://example.com/callback/evil")).to be false
        end

        it "rejects request URIs with a different host even when the path matches" do
          expect(client.valid_redirect_uri?("https://attacker.com/callback")).to be false
        end

        it "rejects subdomain look-alikes (no wildcard matching)" do
          expect(client.valid_redirect_uri?("https://evil.example.com/callback")).to be false
        end

        it "rejects request URIs with a different scheme" do
          expect(client.valid_redirect_uri?("http://example.com/callback")).to be false
        end

        it "rejects relative and malformed URIs" do
          expect(client.valid_redirect_uri?("/callback")).to be false
          expect(client.valid_redirect_uri?("not a url")).to be false
          expect(client.valid_redirect_uri?(nil)).to be false
          expect(client.valid_redirect_uri?("")).to be false
        end

        it "distinguishes between ports" do
          portful_client = described_class.create!(
            owner: account,
            name: "Portful",
            redirect_uris: "https://example.com:8443/cb"
          )
          expect(portful_client.valid_redirect_uri?("https://example.com:8443/cb")).to be true
          expect(portful_client.valid_redirect_uri?("https://example.com/cb")).to be false
        end

        describe "loopback redirects (RFC 8252 §7.3)" do
          let(:loopback_client) do
            described_class.create!(
              owner: account,
              name: "Native App",
              redirect_uris: "http://127.0.0.1/callback",
              client_type: "public",
              require_pkce: true,
              code_challenge_methods: "S256"
            )
          end

          it "matches a loopback request URI on any port for a public PKCE client" do
            expect(loopback_client.valid_redirect_uri?("http://127.0.0.1:53682/callback")).to be true
            expect(loopback_client.valid_redirect_uri?("http://127.0.0.1:1024/callback")).to be true
            expect(loopback_client.valid_redirect_uri?("http://127.0.0.1/callback")).to be true
          end

          it "still requires an exact path match" do
            expect(loopback_client.valid_redirect_uri?("http://127.0.0.1:53682/callback/evil")).to be false
            expect(loopback_client.valid_redirect_uri?("http://127.0.0.1:53682/other")).to be false
          end

          it "requires the http scheme (no https loopback relaxation)" do
            expect(loopback_client.valid_redirect_uri?("https://127.0.0.1:53682/callback")).to be false
          end

          it "does not cross-match 127.0.0.1 and localhost (RFC 8252 §8.3)" do
            expect(loopback_client.valid_redirect_uri?("http://localhost:53682/callback")).to be false
          end

          it "rejects loopback look-alike hosts" do
            expect(loopback_client.valid_redirect_uri?("http://127.0.0.1.evil.com:53682/callback")).to be false
          end

          it "rejects non-loopback hosts" do
            expect(loopback_client.valid_redirect_uri?("http://192.168.1.10:53682/callback")).to be false
            expect(loopback_client.valid_redirect_uri?("http://example.com:53682/callback")).to be false
          end

          it "matches localhost registrations against localhost request URIs only" do
            localhost_client = described_class.create!(
              owner: account,
              name: "Localhost Native App",
              redirect_uris: "http://localhost/callback",
              client_type: "public",
              require_pkce: true,
              code_challenge_methods: "S256"
            )
            expect(localhost_client.valid_redirect_uri?("http://localhost:53682/callback")).to be true
            expect(localhost_client.valid_redirect_uri?("http://127.0.0.1:53682/callback")).to be false
          end

          it "matches IPv6 loopback registrations on any port" do
            ipv6_client = described_class.create!(
              owner: account,
              name: "IPv6 Native App",
              redirect_uris: "http://[::1]/callback",
              client_type: "public",
              require_pkce: true,
              code_challenge_methods: "S256"
            )
            expect(ipv6_client.valid_redirect_uri?("http://[::1]:53682/callback")).to be true
            expect(ipv6_client.valid_redirect_uri?("http://127.0.0.1:53682/callback")).to be false
          end

          it "keeps strict port matching for confidential clients" do
            confidential = described_class.create!(
              owner: account,
              name: "Confidential Loopback",
              redirect_uris: "http://127.0.0.1/callback",
              client_type: "confidential"
            )
            expect(confidential.valid_redirect_uri?("http://127.0.0.1:53682/callback")).to be false
            expect(confidential.valid_redirect_uri?("http://127.0.0.1/callback")).to be true
          end

          it "keeps exact matching for a public client's non-loopback URIs (regression)" do
            public_client = described_class.create!(
              owner: account,
              name: "Public Web",
              redirect_uris: "https://example.com/callback",
              client_type: "public",
              require_pkce: true,
              code_challenge_methods: "S256"
            )
            expect(public_client.valid_redirect_uri?("https://example.com/callback")).to be true
            expect(public_client.valid_redirect_uri?("https://example.com:8443/callback")).to be false
            expect(public_client.valid_redirect_uri?("https://example.com/callback/evil")).to be false
          end
        end
      end
    end

    describe "registered redirect_uris validation" do
      it "rejects registered URIs that contain a query string" do
        bad = described_class.new(owner: account, name: "Bad", redirect_uris: "https://example.com/cb?pre=existing")
        expect(bad).not_to be_valid
        expect(bad.errors[:redirect_uris].join).to include("must not contain a query string")
      end

      it "rejects registered URIs that contain a fragment" do
        bad = described_class.new(owner: account, name: "Bad", redirect_uris: "https://example.com/cb#section")
        expect(bad).not_to be_valid
        expect(bad.errors[:redirect_uris].join).to include("must not contain a fragment")
      end

      it "rejects relative (non-absolute) registered URIs" do
        bad = described_class.new(owner: account, name: "Bad", redirect_uris: "/callback")
        expect(bad).not_to be_valid
        expect(bad.errors[:redirect_uris].join).to include("invalid URI")
      end

      it "accepts multiple whitespace-separated absolute URIs" do
        good = described_class.new(
          owner: account,
          name: "Good",
          redirect_uris: "https://example.com/cb  https://app.example.com/auth"
        )
        expect(good).to be_valid
      end
    end

    describe "client type methods" do
      describe "#confidential?" do
        it "returns true for confidential clients" do
          expect(client.confidential?).to be true
        end

        it "returns false for public clients" do
          client.update!(client_type: "public")
          expect(client.confidential?).to be false
        end
      end

      describe "#public?" do
        it "returns false for confidential clients" do
          expect(client.public?).to be false
        end

        it "returns true for public clients" do
          client.update!(client_type: "public")
          expect(client.public?).to be true
        end
      end
    end

    describe "client secret management" do
      describe "#create_client_secret!" do
        it "creates a new client secret credential" do
          expect {
            client.create_client_secret!(name: "Test Secret", client_secret: "secret123")
          }.to change(client.client_secret_credentials, :count).by(1)

          credential = client.client_secret_credentials.last
          expect(credential.name).to eq("Test Secret")
          expect(credential.client_id).to eq(client.client_id)
          expect(credential.authenticate_client_secret("secret123")).to be_truthy
          expect(credential.scopes).to eq("openid profile email read:users")
        end
      end

      describe "#primary_client_secret" do
        it "returns the first active client secret" do
          secret1 = client.create_client_secret!(name: "Secret 1", client_secret: "secret1")
          secret2 = client.create_client_secret!(name: "Secret 2", client_secret: "secret2")

          expect(client.primary_client_secret).to eq(secret1)
        end

        it "returns nil when no active secrets exist" do
          expect(client.primary_client_secret).to be_nil
        end
      end

      describe "#rotate_client_secret!" do
        let!(:old_secret) { client.create_client_secret!(name: "Old Secret", client_secret: "old_secret") }

        it "creates a new secret and deactivates old ones" do
          expect {
            new_secret = client.rotate_client_secret!(new_secret_name: "New Secret")
            expect(new_secret.name).to eq("New Secret")
            expect(new_secret.active?).to be true
          }.to change(client.client_secret_credentials, :count).by(1)

          old_secret.reload
          expect(old_secret.active?).to be false
          expect(old_secret.revoked_at).to be_present
        end

        it "uses default name when not provided" do
          new_secret = client.rotate_client_secret!
          expect(new_secret.name).to match(/Rotated Secret \d{8}/)
        end
      end

      describe "#authenticate_client_secret" do
        let!(:secret1) { client.create_client_secret!(name: "Secret 1", client_secret: "secret1") }
        let!(:secret2) { client.create_client_secret!(name: "Secret 2", client_secret: "secret2") }

        it "returns the credential that matches the secret" do
          result = client.authenticate_client_secret("secret1")
          expect(result).to eq(secret1)
        end

        it "returns nil for invalid secrets" do
          result = client.authenticate_client_secret("invalid")
          expect(result).to be_nil
        end

        it "ignores inactive credentials" do
          secret1.revoke!
          result = client.authenticate_client_secret("secret1")
          expect(result).to be_nil
        end
      end
    end
  end

  describe "polymorphic owner support" do
    it "can belong to different owner types" do
      # Create a simple test class to simulate different owner types
      organization = Account.create!(name: "Test Org", email: "org@example.com")

      client = described_class.new(
        owner: organization,
        name: "Org Client",
        redirect_uris: "https://example.com"
      )

      expect(client.owner).to eq(organization)
      expect(client.owner_type).to eq("Account")
    end
  end
end
