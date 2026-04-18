require "rails_helper"

RSpec.describe StandardId::AuthorizationCode, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { Account.create!(name: "User", email: "user@example.com") }
  let(:client_id) { "client_123" }
  let(:redirect_uri) { "https://app.example.com/callback" }
  let(:plaintext_code) { SecureRandom.urlsafe_base64(32) }

  describe ".issue! and .lookup" do
    it "creates a hashed record and can be looked up by plaintext" do
      described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        account: account,
        scope: "openid profile",
        audience: "api://default"
      )

      rec = described_class.lookup(plaintext_code)
      expect(rec).to be_present
      expect(rec.client_id).to eq(client_id)
      expect(rec.redirect_uri).to eq(redirect_uri)
      expect(rec.account).to eq(account)
      expect(rec.scope).to eq("openid profile")
      expect(rec.audience).to eq("api://default")
      expect(rec.consumed_at).to be_nil
      expect(rec.expires_at).to be > Time.current
    end
  end

  describe "nonce storage" do
    it "stores nonce when provided" do
      described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        nonce: "abc123nonce"
      )

      rec = described_class.lookup(plaintext_code)
      expect(rec.nonce).to eq("abc123nonce")
    end

    it "allows nil nonce" do
      described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri
      )

      rec = described_class.lookup(plaintext_code)
      expect(rec.nonce).to be_nil
    end
  end

  describe "expiry and single-use" do
    it "expires after TTL and cannot be reused" do
      code = plaintext_code
      rec = described_class.issue!(
        plaintext_code: code,
        client_id: client_id,
        redirect_uri: redirect_uri
      )

      # valid now
      expect(rec.valid_for_client?(client_id)).to be true

      # mark used once
      rec.mark_as_used!
      expect(rec.consumed_at).to be_within(1.second).of(Time.current)

      # second use should raise
      expect { rec.mark_as_used! }.to raise_error(StandardId::InvalidGrantError)

      # time travel to expire a fresh code
      code2 = SecureRandom.urlsafe_base64(32)
      rec2 = described_class.issue!(
        plaintext_code: code2,
        client_id: client_id,
        redirect_uri: redirect_uri
      )

      travel_to(rec2.expires_at + 1.second) do
        expect(rec2.valid_for_client?(client_id)).to be false
        expect { rec2.mark_as_used! }.to raise_error(StandardId::InvalidGrantError)
      end
    end
  end

  describe "PKCE" do
    it "rejects plain method at issuance" do
      expect {
        described_class.issue!(
          plaintext_code: plaintext_code,
          client_id: client_id,
          redirect_uri: redirect_uri,
          code_challenge: "abc123verifier",
          code_challenge_method: "plain"
        )
      }.to raise_error(StandardId::InvalidRequestError, /only S256/)
    end

    it "rejects unknown challenge methods at issuance" do
      expect {
        described_class.issue!(
          plaintext_code: plaintext_code,
          client_id: client_id,
          redirect_uri: redirect_uri,
          code_challenge: "some-challenge",
          code_challenge_method: "unknown"
        )
      }.to raise_error(StandardId::InvalidRequestError, /only S256/)
    end

    it "rejects nil challenge method when challenge is present" do
      expect {
        described_class.issue!(
          plaintext_code: plaintext_code,
          client_id: client_id,
          redirect_uri: redirect_uri,
          code_challenge: "some-challenge",
          code_challenge_method: nil
        )
      }.to raise_error(StandardId::InvalidRequestError, /only S256/)
    end

    it "accepts S256 method when verifier matches hash" do
      verifier = "a-very-long-random-verifier-#{SecureRandom.hex(16)}"
      s256 = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("=")
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: s256,
        code_challenge_method: "S256"
      )
      expect(rec.pkce_valid?(verifier)).to be true
      expect(rec.pkce_valid?("wrong")).to be false
    end

    it "accepts lowercase s256 method" do
      verifier = "a-very-long-random-verifier-#{SecureRandom.hex(16)}"
      s256 = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("=")
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: s256,
        code_challenge_method: "s256"
      )
      expect(rec.pkce_valid?(verifier)).to be true
    end

    it "hashes the code_challenge at storage time" do
      verifier = "a-very-long-random-verifier-#{SecureRandom.hex(16)}"
      s256 = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("=")
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: s256,
        code_challenge_method: "S256"
      )
      # Stored value is SHA256(S256_challenge), not the raw challenge
      expect(rec.code_challenge).to eq(Digest::SHA256.hexdigest(s256))
      expect(rec.code_challenge).not_to eq(s256)
    end

    it "validates legacy codes with unhashed challenge (in-flight during deployment)" do
      verifier = "a-very-long-random-verifier-#{SecureRandom.hex(16)}"
      s256 = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("=")

      # Simulate a pre-RAR-58 code with raw (unhashed) challenge stored directly
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: s256,
        code_challenge_method: "S256"
      )
      # Overwrite the hashed value with the raw challenge to simulate legacy storage
      rec.update_column(:code_challenge, s256)

      expect(rec.pkce_valid?(verifier)).to be true
      expect(rec.pkce_valid?("wrong")).to be false
    end

    it "skips PKCE verification when no challenge was stored" do
      # When a client legitimately opts out (require_pkce: false) and no
      # code_challenge was issued, pkce_valid? returns true regardless of
      # the verifier argument. This preserves the escape hatch for
      # confidential clients that choose not to participate in PKCE.
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri
      )
      expect(rec.code_challenge).to be_nil
      expect(rec.pkce_valid?(nil)).to be true
    end

    describe "per-client PKCE method support" do
      let(:owner) { Account.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com") }
      let(:verifier) { "a-very-long-random-verifier-#{SecureRandom.hex(16)}" }
      let(:s256) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("=") }

      it "defers to client.supports_pkce_method? when the client requires PKCE" do
        client = StandardId::ClientApplication.create!(
          owner: owner,
          name: "Client With PKCE",
          redirect_uris: redirect_uri,
          require_pkce: true,
          code_challenge_methods: "S256"
        )

        expect {
          described_class.issue!(
            plaintext_code: plaintext_code,
            client_id: client.client_id,
            redirect_uri: redirect_uri,
            code_challenge: s256,
            code_challenge_method: "S256"
          )
        }.not_to raise_error
      end

      it "accepts case-insensitive method via client.supports_pkce_method?" do
        # Directly exercises the case-insensitive comparison in
        # supports_pkce_method? against a real ClientApplication record
        # (rather than falling through to the S256-only fallback).
        client = StandardId::ClientApplication.create!(
          owner: owner,
          name: "Client With Uppercase S256",
          redirect_uris: redirect_uri,
          require_pkce: true,
          code_challenge_methods: "S256"
        )

        expect {
          described_class.issue!(
            plaintext_code: plaintext_code,
            client_id: client.client_id,
            redirect_uri: redirect_uri,
            code_challenge: s256,
            code_challenge_method: "s256"
          )
        }.not_to raise_error
      end

      it "falls back to S256-only when client record is missing" do
        expect {
          described_class.issue!(
            plaintext_code: plaintext_code,
            client_id: "unknown_client_id",
            redirect_uri: redirect_uri,
            code_challenge: s256,
            code_challenge_method: "plain"
          )
        }.to raise_error(StandardId::InvalidRequestError, /only S256/)
      end

      it "falls back to S256-only when client opts out of PKCE but still sends a challenge" do
        client = StandardId::ClientApplication.create!(
          owner: owner,
          name: "Confidential Opt Out",
          redirect_uris: redirect_uri,
          client_type: "confidential",
          require_pkce: false,
          code_challenge_methods: nil
        )

        expect {
          described_class.issue!(
            plaintext_code: plaintext_code,
            client_id: client.client_id,
            redirect_uri: redirect_uri,
            code_challenge: s256,
            code_challenge_method: "plain"
          )
        }.to raise_error(StandardId::InvalidRequestError, /only S256/)
      end
    end
  end
end
