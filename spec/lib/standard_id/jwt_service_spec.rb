require "rails_helper"

RSpec.describe StandardId::JwtService do
  # Generate test keys once for the spec file
  let(:rsa_private_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:ec_private_key) { OpenSSL::PKey::EC.generate("prime256v1") }

  after do
    # Reset cached values between tests
    described_class.reset_cached_key!
  end

  describe ".algorithm" do
    it "defaults to HS256" do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
      expect(described_class.algorithm).to eq("HS256")
    end

    it "returns uppercase algorithm from config" do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
      expect(described_class.algorithm).to eq("RS256")
    end
  end

  describe ".asymmetric?" do
    it "returns false for HS256" do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
      expect(described_class.asymmetric?).to be false
    end

    it "returns true for RS256" do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
      expect(described_class.asymmetric?).to be true
    end

    it "returns true for ES256" do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:es256)
      expect(described_class.asymmetric?).to be true
    end

    it "raises error for unsupported algorithm" do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:none)
      expect { described_class.asymmetric? }.to raise_error(ArgumentError, /Unsupported algorithm: NONE/)
    end

    it "raises error with list of supported algorithms" do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:invalid)
      expect { described_class.asymmetric? }.to raise_error(ArgumentError, /Supported: HS256, HS384, HS512, RS256/)
    end
  end

  describe ".encode and .decode" do
    context "with HS256 (default symmetric)" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(nil)
        allow(StandardId.config).to receive(:issuer).and_return(nil)
      end

      it "encodes and decodes a token" do
        payload = { sub: "user-123", data: "test" }
        token = described_class.encode(payload)

        decoded = described_class.decode(token)
        expect(decoded["sub"]).to eq("user-123")
        expect(decoded["data"]).to eq("test")
      end

      it "includes exp and iat claims" do
        token = described_class.encode({ sub: "user-123" })
        decoded = described_class.decode(token)

        expect(decoded["exp"]).to be_present
        expect(decoded["iat"]).to be_present
      end

      it "does not include kid header" do
        token = described_class.encode({ sub: "user-123" })
        header = JWT.decode(token, nil, false).last

        expect(header["kid"]).to be_nil
      end
    end

    context "with RS256 (RSA asymmetric)" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(rsa_private_key.to_pem)
        allow(StandardId.config).to receive(:issuer).and_return(nil)
      end

      it "encodes and decodes a token with RSA key" do
        payload = { sub: "user-123", data: "test" }
        token = described_class.encode(payload)

        decoded = described_class.decode(token)
        expect(decoded["sub"]).to eq("user-123")
        expect(decoded["data"]).to eq("test")
      end

      it "includes kid header for asymmetric tokens" do
        token = described_class.encode({ sub: "user-123" })
        header = JWT.decode(token, nil, false).last

        expect(header["kid"]).to be_present
        expect(header["kid"].length).to eq(8)
      end

      it "can verify token with public key" do
        token = described_class.encode({ sub: "user-123" })

        # Verify using just the public key
        decoded = JWT.decode(token, rsa_private_key.public_key, true, { algorithm: "RS256" })
        expect(decoded.first["sub"]).to eq("user-123")
      end
    end

    context "with ES256 (ECDSA asymmetric)" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:es256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(ec_private_key.to_pem)
        allow(StandardId.config).to receive(:issuer).and_return(nil)
      end

      it "encodes and decodes a token with EC key" do
        payload = { sub: "user-123", data: "test" }
        token = described_class.encode(payload)

        decoded = described_class.decode(token)
        expect(decoded["sub"]).to eq("user-123")
        expect(decoded["data"]).to eq("test")
      end

      it "includes kid header for asymmetric tokens" do
        token = described_class.encode({ sub: "user-123" })
        header = JWT.decode(token, nil, false).last

        expect(header["kid"]).to be_present
      end
    end

    context "with issuer configured" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(nil)
        allow(StandardId.config).to receive(:issuer).and_return("https://auth.example.com")
      end

      it "includes iss claim in token" do
        token = described_class.encode({ sub: "user-123" })
        decoded = described_class.decode(token)

        expect(decoded["iss"]).to eq("https://auth.example.com")
      end

      it "verifies issuer on decode" do
        token = described_class.encode({ sub: "user-123" })

        # Should decode successfully with matching issuer
        expect(described_class.decode(token)).to be_present
      end

      it "rejects tokens with wrong issuer" do
        # Create a token with wrong issuer
        wrong_issuer_token = JWT.encode(
          { sub: "user-123", iss: "https://wrong.example.com", exp: 1.hour.from_now.to_i },
          Rails.application.secret_key_base,
          "HS256"
        )

        expect(described_class.decode(wrong_issuer_token)).to be_nil
      end

      it "does not override explicit iss in payload" do
        token = described_class.encode({ sub: "user-123", iss: "https://custom.example.com" })
        decoded = JWT.decode(token, nil, false).first

        expect(decoded["iss"]).to eq("https://custom.example.com")
      end
    end
  end

  describe ".key_id" do
    context "with symmetric algorithm" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
      end

      it "returns nil for HS256" do
        expect(described_class.key_id).to be_nil
      end
    end

    context "with asymmetric algorithm" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(rsa_private_key.to_pem)
      end

      it "returns a stable key ID based on public key fingerprint" do
        key_id1 = described_class.key_id
        described_class.reset_cached_key!
        key_id2 = described_class.key_id

        expect(key_id1).to eq(key_id2)
        expect(key_id1.length).to eq(8)
      end
    end
  end

  describe ".jwks" do
    context "with symmetric algorithm" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
      end

      it "returns nil for HS256" do
        expect(described_class.jwks).to be_nil
      end
    end

    context "with RS256" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(rsa_private_key.to_pem)
      end

      it "returns a valid JWKS structure" do
        jwks = described_class.jwks

        expect(jwks).to be_a(Hash)
        expect(jwks[:keys]).to be_an(Array)
        expect(jwks[:keys].length).to eq(1)
      end

      it "includes RSA key parameters" do
        jwks = described_class.jwks
        key = jwks[:keys].first

        expect(key[:kty]).to eq("RSA")
        expect(key[:kid]).to eq(described_class.key_id)
        expect(key[:n]).to be_present # modulus
        expect(key[:e]).to be_present # exponent
      end

      it "does not expose private key material" do
        jwks = described_class.jwks
        key = jwks[:keys].first

        # Private key components should not be present
        expect(key[:d]).to be_nil
        expect(key[:p]).to be_nil
        expect(key[:q]).to be_nil
      end

      it "can be used to verify tokens" do
        token = described_class.encode({ sub: "user-123" })
        jwks = described_class.jwks

        # Create a JWKS from the exported keys
        jwk_set = JWT::JWK::Set.new(jwks)
        algorithms = jwks[:keys].map { |k| k[:alg] }.compact
        algorithms = ["RS256"] if algorithms.empty?

        decoded = JWT.decode(token, nil, true, { algorithms: algorithms, jwks: jwk_set })
        expect(decoded.first["sub"]).to eq("user-123")
      end

      it "caches the JWKS response" do
        jwks1 = described_class.jwks
        jwks2 = described_class.jwks

        # Same object reference means it's cached
        expect(jwks1).to be(jwks2)
      end

      it "clears cache when reset_cached_key! is called" do
        jwks1 = described_class.jwks
        described_class.reset_cached_key!
        jwks2 = described_class.jwks

        # Different object reference after cache clear
        expect(jwks1).not_to be(jwks2)
        # But same content (since same key)
        expect(jwks1[:keys].first[:kid]).to eq(jwks2[:keys].first[:kid])
      end
    end

    context "with ES256" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:es256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(ec_private_key.to_pem)
      end

      it "returns a valid JWKS structure" do
        jwks = described_class.jwks

        expect(jwks).to be_a(Hash)
        expect(jwks[:keys]).to be_an(Array)
        expect(jwks[:keys].length).to eq(1)
      end

      it "includes EC key parameters" do
        jwks = described_class.jwks
        key = jwks[:keys].first

        expect(key[:kty]).to eq("EC")
        expect(key[:kid]).to eq(described_class.key_id)
        expect(key[:crv]).to be_present # curve
        expect(key[:x]).to be_present
        expect(key[:y]).to be_present
      end

      it "does not expose private key material" do
        jwks = described_class.jwks
        key = jwks[:keys].first

        # Private key component should not be present
        expect(key[:d]).to be_nil
      end
    end
  end

  describe ".decode_session" do
    let(:payload) do
      {
        sub: "account-123",
        client_id: "client-456",
        scope: "openid profile",
        grant_type: "password",
        aud: "https://example.com",
        custom_flag: true,
        metadata: { "plan" => "pro" }
      }
    end

    before do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
      allow(StandardId.config.oauth).to receive(:signing_key).and_return(nil)
      allow(StandardId.config).to receive(:issuer).and_return(nil)
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({})
    end

    it "returns custom_claims with non-reserved payload keys" do
      token = described_class.encode(payload, expires_in: 5.minutes)

      session = described_class.decode_session(token)

      expect(session.scopes).to eq(%w[openid profile])
      expect(session).not_to respond_to(:custom_flag)
      expect(session).not_to respond_to(:metadata)
    end

    context "when claim resolvers are configured" do
      before do
        reset_jwt_session_class!

        allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({
          custom_flag: ->(**) { },
          metadata: ->(**) { },
          other_claims: ->(**) { }
        })
      end

      it "exposes direct accessors for configured claim keys" do
        token = described_class.encode(payload, expires_in: 5.minutes)

        session = described_class.decode_session(token)

        expect(session.custom_flag).to eq(true)
        expect(session.metadata).to eq({ "plan" => "pro" })
        expect(session.other_claims).to be_nil
      end
    end
  end

  describe "key rotation" do
    let(:old_rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
    let(:new_rsa_key) { OpenSSL::PKey::RSA.generate(2048) }

    before do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
      allow(StandardId.config.oauth).to receive(:signing_key).and_return(new_rsa_key.to_pem)
      allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return([old_rsa_key.to_pem])
      allow(StandardId.config).to receive(:issuer).and_return(nil)
    end

    describe ".previous_keys" do
      it "returns parsed previous keys with kid and verification key" do
        keys = described_class.previous_keys

        expect(keys.length).to eq(1)
        expect(keys.first[:kid]).to be_a(String)
        expect(keys.first[:kid].length).to eq(8)
        expect(keys.first[:key]).to be_a(OpenSSL::PKey::RSA)
      end

      it "returns empty array when no previous keys configured" do
        allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return([])
        expect(described_class.previous_keys).to eq([])
      end

      it "skips invalid key entries gracefully" do
        allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return(["invalid-pem", old_rsa_key.to_pem])
        keys = described_class.previous_keys

        expect(keys.length).to eq(1)
      end
    end

    describe ".all_verification_keys" do
      it "returns current key plus previous keys" do
        keys = described_class.all_verification_keys

        expect(keys.length).to eq(2)
        expect(keys.map { |k| k[:kid] }.uniq.length).to eq(2)
      end

      it "puts current key first" do
        keys = described_class.all_verification_keys

        expect(keys.first[:kid]).to eq(described_class.key_id)
      end
    end

    describe "decoding tokens signed with previous key" do
      it "decodes tokens signed with the old key" do
        # Sign a token with the old key
        old_kid = Digest::SHA256.hexdigest(old_rsa_key.public_to_pem)[0..7]
        token = JWT.encode(
          { sub: "user-123", exp: 1.hour.from_now.to_i, iat: Time.current.to_i },
          old_rsa_key,
          "RS256",
          { kid: old_kid }
        )

        decoded = described_class.decode(token)
        expect(decoded["sub"]).to eq("user-123")
      end

      it "decodes tokens signed with the new (current) key" do
        token = described_class.encode({ sub: "user-456" })

        decoded = described_class.decode(token)
        expect(decoded["sub"]).to eq("user-456")
      end

      it "rejects tokens signed with an unknown key" do
        unknown_key = OpenSSL::PKey::RSA.generate(2048)
        token = JWT.encode(
          { sub: "user-789", exp: 1.hour.from_now.to_i, iat: Time.current.to_i },
          unknown_key,
          "RS256",
          { kid: "unknown1" }
        )

        expect(described_class.decode(token)).to be_nil
      end
    end

    describe ".jwks with rotation" do
      it "returns all keys in JWKS" do
        jwks = described_class.jwks

        expect(jwks[:keys].length).to eq(2)
      end

      it "includes kids for all keys" do
        jwks = described_class.jwks
        kids = jwks[:keys].map { |k| k[:kid] }

        expect(kids.length).to eq(2)
        expect(kids.uniq.length).to eq(2)
        expect(kids).to include(described_class.key_id)
      end

      it "can verify tokens signed with any listed key" do
        jwks = described_class.jwks
        jwk_set = JWT::JWK::Set.new(jwks)

        # Token signed with old key
        old_kid = Digest::SHA256.hexdigest(old_rsa_key.public_to_pem)[0..7]
        old_token = JWT.encode(
          { sub: "old-user", exp: 1.hour.from_now.to_i },
          old_rsa_key, "RS256", { kid: old_kid }
        )

        # Token signed with new key
        new_token = described_class.encode({ sub: "new-user" })

        old_decoded = JWT.decode(old_token, nil, true, { algorithms: ["RS256"], jwks: jwk_set })
        new_decoded = JWT.decode(new_token, nil, true, { algorithms: ["RS256"], jwks: jwk_set })

        expect(old_decoded.first["sub"]).to eq("old-user")
        expect(new_decoded.first["sub"]).to eq("new-user")
      end
    end

    describe ".reset_cached_key!" do
      it "clears previous keys cache" do
        # Populate cache
        described_class.previous_keys
        described_class.reset_cached_key!

        # Should re-read from config
        allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return([])
        expect(described_class.previous_keys).to eq([])
      end
    end
  end

  describe "cross-algorithm key rotation" do
    let(:old_rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
    let(:new_ec_key) { OpenSSL::PKey::EC.generate("prime256v1") }

    before do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:es256)
      allow(StandardId.config.oauth).to receive(:signing_key).and_return(new_ec_key.to_pem)
      allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return([
        { key: old_rsa_key.to_pem, algorithm: :rs256 }
      ])
      allow(StandardId.config).to receive(:issuer).and_return(nil)
    end

    describe ".previous_keys" do
      it "parses previous key with explicit algorithm" do
        keys = described_class.previous_keys

        expect(keys.length).to eq(1)
        expect(keys.first[:algorithm]).to eq("RS256")
        expect(keys.first[:key]).to be_a(OpenSSL::PKey::RSA)
      end
    end

    describe ".all_verification_keys" do
      it "includes both EC and RSA keys" do
        keys = described_class.all_verification_keys

        expect(keys.length).to eq(2)
        key_types = keys.map { |k| k[:key].class }
        expect(key_types).to include(OpenSSL::PKey::EC)
        expect(key_types).to include(OpenSSL::PKey::RSA)
      end
    end

    it "decodes tokens signed with the old RSA key" do
      old_kid = Digest::SHA256.hexdigest(old_rsa_key.public_to_pem)[0..7]
      token = JWT.encode(
        { sub: "rsa-user", exp: 1.hour.from_now.to_i, iat: Time.current.to_i },
        old_rsa_key,
        "RS256",
        { kid: old_kid }
      )

      decoded = described_class.decode(token)
      expect(decoded["sub"]).to eq("rsa-user")
    end

    it "decodes tokens signed with the new EC key" do
      token = described_class.encode({ sub: "ec-user" })

      decoded = described_class.decode(token)
      expect(decoded["sub"]).to eq("ec-user")
    end

    it "JWKS contains both RSA and EC keys" do
      jwks = described_class.jwks
      key_types = jwks[:keys].map { |k| k[:kty] }

      expect(key_types).to contain_exactly("EC", "RSA")
    end

    it "new tokens use the new EC key's kid" do
      token = described_class.encode({ sub: "user-123" })
      header = JWT.decode(token, nil, false).last

      expect(header["kid"]).to eq(described_class.key_id)
      expect(header["alg"]).to eq("ES256")
    end
  end

  describe "signing key from file path" do
    before do
      allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
    end

    it "reads key from Pathname" do
      # Create a temp file with the key
      require "tempfile"
      tempfile = Tempfile.new(["test_key", ".pem"])
      tempfile.write(rsa_private_key.to_pem)
      tempfile.close

      allow(StandardId.config.oauth).to receive(:signing_key).and_return(Pathname.new(tempfile.path))
      allow(StandardId.config).to receive(:issuer).and_return(nil)

      token = described_class.encode({ sub: "user-123" })
      decoded = described_class.decode(token)

      expect(decoded["sub"]).to eq("user-123")

      tempfile.unlink
    end
  end
end
