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
        decoded = JWT.decode(token, rsa_private_key.public_key, true, { algorithms: ["RS256"] })
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

    context "with audience verification" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(nil)
        allow(StandardId.config).to receive(:issuer).and_return(nil)
      end

      it "decodes successfully when aud matches allowed_audiences" do
        token = described_class.encode({ sub: "user-123", aud: "web" })

        decoded = described_class.decode(token, allowed_audiences: ["web"])

        expect(decoded["sub"]).to eq("user-123")
        expect(decoded["aud"]).to eq("web")
      end

      it "decodes successfully when aud is in a multi-audience allow list" do
        token = described_class.encode({ sub: "user-123", aud: "mobile" })

        decoded = described_class.decode(token, allowed_audiences: %w[web mobile admin])

        expect(decoded["sub"]).to eq("user-123")
      end

      it "accepts an array aud when one element matches" do
        token = described_class.encode({ sub: "user-123", aud: %w[web mobile] })

        decoded = described_class.decode(token, allowed_audiences: ["mobile"])

        expect(decoded["sub"]).to eq("user-123")
      end

      it "raises InvalidAudienceError when aud does not match allowed_audiences" do
        token = described_class.encode({ sub: "user-123", aud: "admin" })

        expect {
          described_class.decode(token, allowed_audiences: ["web"])
        }.to raise_error(StandardId::InvalidAudienceError) do |error|
          expect(error.required).to eq(["web"])
          expect(error.actual).to eq(["admin"])
        end
      end

      it "raises InvalidAudienceError when token has no aud claim" do
        token = described_class.encode({ sub: "user-123" })

        expect {
          described_class.decode(token, allowed_audiences: ["web"])
        }.to raise_error(StandardId::InvalidAudienceError)
      end

      it "does not enforce audience when allowed_audiences is nil (default)" do
        token = described_class.encode({ sub: "user-123", aud: "admin" })

        decoded = described_class.decode(token)

        expect(decoded["sub"]).to eq("user-123")
        expect(decoded["aud"]).to eq("admin")
      end

      it "does not enforce audience when allowed_audiences is an empty array" do
        token = described_class.encode({ sub: "user-123", aud: "admin" })

        decoded = described_class.decode(token, allowed_audiences: [])

        expect(decoded["sub"]).to eq("user-123")
      end

      it "still returns nil for invalid signature even when allowed_audiences is set" do
        tampered = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.invalid"

        expect(described_class.decode(tampered, allowed_audiences: ["web"])).to be_nil
      end

      it "still returns nil for expired tokens" do
        token = described_class.encode({ sub: "user-123", aud: "web" }, expires_in: -1.hour)

        expect(described_class.decode(token, allowed_audiences: ["web"])).to be_nil
      end

      context "with asymmetric algorithm and key rotation (JWKS path)" do
        let(:old_rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
        let(:new_rsa_key) { OpenSSL::PKey::RSA.generate(2048) }

        before do
          allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
          allow(StandardId.config.oauth).to receive(:signing_key).and_return(new_rsa_key.to_pem)
          allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return([old_rsa_key.to_pem])
        end

        it "decodes successfully when aud matches" do
          token = described_class.encode({ sub: "user-123", aud: "web" })

          decoded = described_class.decode(token, allowed_audiences: ["web"])

          expect(decoded["sub"]).to eq("user-123")
        end

        it "raises InvalidAudienceError when aud does not match" do
          token = described_class.encode({ sub: "user-123", aud: "admin" })

          expect {
            described_class.decode(token, allowed_audiences: ["web"])
          }.to raise_error(StandardId::InvalidAudienceError) do |error|
            expect(error.required).to eq(["web"])
            expect(error.actual).to eq(["admin"])
          end
        end
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
        expect(key[:alg]).to eq("RS256")
        expect(key[:use]).to eq("sig")
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
        algorithms = jwks[:keys].map { |k| k[:alg] }

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
        expect(key[:alg]).to eq("ES256")
        expect(key[:use]).to eq("sig")
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

    it "returns standard fields accessible as before" do
      token = described_class.encode(payload, expires_in: 5.minutes)

      session = described_class.decode_session(token)

      expect(session.account_id).to eq("account-123")
      expect(session.client_id).to eq("client-456")
      expect(session.scopes).to eq(%w[openid profile])
      expect(session.grant_type).to eq("password")
      expect(session.aud).to eq("https://example.com")
      expect(session.active?).to be true
    end

    it "does not expose non-resolver custom payload keys as struct fields" do
      token = described_class.encode(payload, expires_in: 5.minutes)

      session = described_class.decode_session(token)

      expect(session).not_to respond_to(:custom_flag)
      expect(session).not_to respond_to(:metadata)
    end

    it "populates claims with the full decoded JWT payload hash" do
      token = described_class.encode(payload, expires_in: 5.minutes)

      session = described_class.decode_session(token)

      expect(session.claims).to be_a(Hash)
      expect(session.claims["sub"]).to eq("account-123")
      expect(session.claims["client_id"]).to eq("client-456")
      expect(session.claims["scope"]).to eq("openid profile")
      expect(session.claims["grant_type"]).to eq("password")
      expect(session.claims["aud"]).to eq("https://example.com")
      expect(session.claims["exp"]).to be_present
      expect(session.claims["iat"]).to be_present
    end

    it "includes non-standard claims in the claims hash" do
      token = described_class.encode(payload, expires_in: 5.minutes)

      session = described_class.decode_session(token)

      expect(session.claims["custom_flag"]).to eq(true)
      expect(session.claims["metadata"]).to eq({ "plan" => "pro" })
    end

    it "allows custom claim access like session.claims['channel_id']" do
      custom_payload = payload.merge(channel_id: "ch-789")
      token = described_class.encode(custom_payload, expires_in: 5.minutes)

      session = described_class.decode_session(token)

      expect(session.claims["channel_id"]).to eq("ch-789")
    end

    it "returns nil when token is invalid" do
      expect(described_class.decode_session("invalid.token.here")).to be_nil
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

    it "JWKS contains both RSA and EC keys with correct alg and use" do
      jwks = described_class.jwks
      key_types = jwks[:keys].map { |k| k[:kty] }
      algorithms = jwks[:keys].map { |k| k[:alg] }

      expect(key_types).to contain_exactly("EC", "RSA")
      expect(algorithms).to contain_exactly("ES256", "RS256")
      jwks[:keys].each { |k| expect(k[:use]).to eq("sig") }
    end

    it "new tokens use the new EC key's kid" do
      token = described_class.encode({ sub: "user-123" })
      header = JWT.decode(token, nil, false).last

      expect(header["kid"]).to eq(described_class.key_id)
      expect(header["alg"]).to eq("ES256")
    end
  end

  describe ".sign and .verify primitives" do
    let(:hs_key) { "a" * 64 }

    describe "round-trip" do
      it "round-trips with HS256" do
        payload = { sub: "svc-1", scope: "tools:invoke" }
        token = described_class.sign(payload, algorithm: "HS256", key: hs_key)
        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)

        expect(decoded["sub"]).to eq("svc-1")
        expect(decoded["scope"]).to eq("tools:invoke")
      end

      it "round-trips with RS256" do
        payload = { sub: "svc-2" }
        token = described_class.sign(payload, algorithm: "RS256", key: rsa_private_key)
        decoded = described_class.verify(token, algorithm: "RS256", key: rsa_private_key.public_key)

        expect(decoded["sub"]).to eq("svc-2")
      end

      it "round-trips with ES256" do
        payload = { sub: "svc-3" }
        token = described_class.sign(payload, algorithm: "ES256", key: ec_private_key)
        decoded = described_class.verify(token, algorithm: "ES256", key: ec_private_key)

        expect(decoded["sub"]).to eq("svc-3")
      end
    end

    describe "does not consult StandardId config" do
      it "ignores configured issuer" do
        allow(StandardId.config).to receive(:issuer).and_return("https://configured.example")

        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key)
        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)

        expect(decoded).not_to have_key("iss")
      end

      it "does not auto-add iat" do
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key)
        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)

        expect(decoded).not_to have_key("iat")
      end
    end

    describe "expires_in" do
      it "auto-adds an exp claim" do
        freeze_time = Time.at(1_700_000_000)
        allow(Time).to receive(:now).and_return(freeze_time)

        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key, expires_in: 60)
        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)

        expect(decoded["exp"]).to eq((freeze_time + 60).to_i)
      end

      it "rejects expired tokens" do
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key, expires_in: -60)

        expect {
          described_class.verify(token, algorithm: "HS256", key: hs_key)
        }.to raise_error(StandardId::ExpiredTokenError)
      end

      it "can skip expiration verification" do
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key, expires_in: -60)

        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key, verify_expiration: false)
        expect(decoded["sub"]).to eq("svc")
      end

      it "does not add exp when expires_in is nil" do
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key)
        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)

        expect(decoded).not_to have_key("exp")
      end

      it "preserves caller-supplied exp over expires_in" do
        explicit_exp = (Time.now + 10).to_i
        token = described_class.sign(
          { sub: "svc", exp: explicit_exp },
          algorithm: "HS256",
          key: hs_key,
          expires_in: 9999
        )

        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)
        expect(decoded["exp"]).to eq(explicit_exp)
      end

      it "preserves caller-supplied string-keyed exp over expires_in" do
        explicit_exp = (Time.now + 10).to_i
        token = described_class.sign(
          { "sub" => "svc", "exp" => explicit_exp },
          algorithm: "HS256",
          key: hs_key,
          expires_in: 9999
        )

        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)
        expect(decoded["exp"]).to eq(explicit_exp)
      end
    end

    describe "not_before" do
      it "rejects tokens with a future nbf" do
        token = described_class.sign(
          { sub: "svc", nbf: (Time.now + 300).to_i },
          algorithm: "HS256", key: hs_key
        )

        expect {
          described_class.verify(token, algorithm: "HS256", key: hs_key)
        }.to raise_error(StandardId::InvalidTokenError)
      end

      it "can skip nbf verification via verify_not_before: false" do
        token = described_class.sign(
          { sub: "svc", nbf: (Time.now + 300).to_i },
          algorithm: "HS256", key: hs_key
        )

        decoded = described_class.verify(
          token, algorithm: "HS256", key: hs_key, verify_not_before: false
        )
        expect(decoded["sub"]).to eq("svc")
      end

      it "does not retry every rotation key on a future-nbf token" do
        token = described_class.sign(
          { sub: "svc", nbf: (Time.now + 300).to_i },
          algorithm: "HS256", key: hs_key
        )

        # If the ImmatureSignature rescue didn't early-exit, each key in the
        # rotation list would be attempted. We assert that the token bails
        # as soon as nbf fails by stubbing a tripwire on a later key: a
        # "wrong-key" that would raise a different error class if we reached it.
        tripwire_key = "wrong-" + "x" * 60

        expect {
          described_class.verify(
            token,
            algorithm: "HS256",
            key: [hs_key, tripwire_key]
          )
        }.to raise_error(StandardId::InvalidTokenError) { |err|
          expect(err).not_to be_a(StandardId::InvalidSignatureError)
        }
      end
    end

    describe "algorithm 'none' footgun" do
      it "refuses to sign with algorithm 'none'" do
        expect {
          described_class.sign({ sub: "svc" }, algorithm: "none", key: hs_key)
        }.to raise_error(ArgumentError, /'none' is not permitted/)
      end

      it "refuses case variants of 'none' (uppercase/mixed)" do
        expect {
          described_class.sign({ sub: "svc" }, algorithm: "NONE", key: hs_key)
        }.to raise_error(ArgumentError, /'none' is not permitted/)

        expect {
          described_class.sign({ sub: "svc" }, algorithm: "None", key: hs_key)
        }.to raise_error(ArgumentError, /'none' is not permitted/)
      end
    end

    describe "wrong key" do
      it "raises InvalidSignatureError when HS256 key does not match" do
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key)

        expect {
          described_class.verify(token, algorithm: "HS256", key: "wrong-key-" + "x" * 60)
        }.to raise_error(StandardId::InvalidSignatureError)
      end

      it "raises InvalidSignatureError when RS256 public key does not match" do
        other_key = OpenSSL::PKey::RSA.generate(2048)
        token = described_class.sign({ sub: "svc" }, algorithm: "RS256", key: rsa_private_key)

        expect {
          described_class.verify(token, algorithm: "RS256", key: other_key.public_key)
        }.to raise_error(StandardId::InvalidSignatureError)
      end
    end

    describe "algorithm mismatch" do
      it "raises InvalidAlgorithmError when token alg is not in allowed list" do
        # Token signed with HS256, but caller expects RS256
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key)

        expect {
          described_class.verify(token, algorithm: "RS256", key: rsa_private_key.public_key)
        }.to raise_error(StandardId::InvalidAlgorithmError)
      end

      it "accepts any algorithm from a list of allowed algorithms" do
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key)

        decoded = described_class.verify(token, algorithm: %w[HS256 HS512], key: hs_key)
        expect(decoded["sub"]).to eq("svc")
      end
    end

    describe "allowed_audiences" do
      it "accepts token when aud matches one of the allowed audiences" do
        token = described_class.sign({ sub: "svc", aud: "sidekick" }, algorithm: "HS256", key: hs_key)

        decoded = described_class.verify(
          token,
          algorithm: "HS256",
          key: hs_key,
          allowed_audiences: %w[sidekick other]
        )
        expect(decoded["aud"]).to eq("sidekick")
      end

      it "rejects token when aud does not match" do
        token = described_class.sign({ sub: "svc", aud: "other" }, algorithm: "HS256", key: hs_key)

        expect {
          described_class.verify(
            token,
            algorithm: "HS256",
            key: hs_key,
            allowed_audiences: %w[sidekick]
          )
        }.to raise_error(StandardId::InvalidAudienceTokenError)
      end

      it "does not enforce aud when allowed_audiences is nil" do
        token = described_class.sign({ sub: "svc", aud: "anything" }, algorithm: "HS256", key: hs_key)

        decoded = described_class.verify(token, algorithm: "HS256", key: hs_key)
        expect(decoded["aud"]).to eq("anything")
      end

      it "accepts a single string audience" do
        token = described_class.sign({ sub: "svc", aud: "sidekick" }, algorithm: "HS256", key: hs_key)

        decoded = described_class.verify(
          token,
          algorithm: "HS256",
          key: hs_key,
          allowed_audiences: "sidekick"
        )
        expect(decoded["sub"]).to eq("svc")
      end
    end

    describe "key rotation via array of keys" do
      it "accepts a token when any of the candidate keys match" do
        old_key = "old-secret-" + "x" * 54
        new_key = "new-secret-" + "y" * 54

        # Signed with the new key, caller tries new first then old
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: new_key)
        decoded = described_class.verify(
          token,
          algorithm: "HS256",
          key: [new_key, old_key]
        )
        expect(decoded["sub"]).to eq("svc")
      end

      it "accepts a token when the matching key is not first in the array" do
        old_key = "old-secret-" + "x" * 54
        new_key = "new-secret-" + "y" * 54

        # Signed with old, but old is second in the list
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: old_key)
        decoded = described_class.verify(
          token,
          algorithm: "HS256",
          key: [new_key, old_key]
        )
        expect(decoded["sub"]).to eq("svc")
      end

      it "raises InvalidSignatureError when no key matches" do
        wrong_a = "wrong-a-" + "x" * 56
        wrong_b = "wrong-b-" + "y" * 56

        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: "real-secret-" + "z" * 54)

        expect {
          described_class.verify(token, algorithm: "HS256", key: [wrong_a, wrong_b])
        }.to raise_error(StandardId::InvalidSignatureError)
      end

      it "raises when the keys array is empty" do
        token = described_class.sign({ sub: "svc" }, algorithm: "HS256", key: hs_key)

        expect {
          described_class.verify(token, algorithm: "HS256", key: [])
        }.to raise_error(StandardId::InvalidTokenError, /At least one verification key/)
      end
    end

    describe "extra_headers" do
      it "passes through arbitrary header fields like kid" do
        token = described_class.sign(
          { sub: "svc" },
          algorithm: "HS256",
          key: hs_key,
          kid: "service-key-1"
        )

        header = JWT.decode(token, nil, false).last
        expect(header["kid"]).to eq("service-key-1")
      end
    end

    describe "garbage token" do
      it "raises InvalidTokenError on malformed input" do
        expect {
          described_class.verify("not.a.token", algorithm: "HS256", key: hs_key)
        }.to raise_error(StandardId::InvalidTokenError)
      end
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
