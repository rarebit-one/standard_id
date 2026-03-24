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
    it "rejects plain method (only S256 is supported)" do
      verifier = "abc123verifier"
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: verifier,
        code_challenge_method: "plain"
      )
      expect(rec.pkce_valid?(verifier)).to be false
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
      # Stored value should be a SHA256 hex digest, not the original challenge
      expect(rec.code_challenge).to eq(Digest::SHA256.hexdigest(s256))
      expect(rec.code_challenge).not_to eq(s256)
    end

    it "skips PKCE when no challenge present" do
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri
      )
      expect(rec.pkce_valid?(nil)).to be true
    end

    it "rejects unknown challenge methods" do
      rec = described_class.issue!(
        plaintext_code: plaintext_code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: "some-challenge",
        code_challenge_method: "unknown"
      )
      expect(rec.pkce_valid?("some-challenge")).to be false
    end
  end
end
