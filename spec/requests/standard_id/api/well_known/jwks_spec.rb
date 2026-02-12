require "rails_helper"

RSpec.describe "StandardId API JWKS Endpoint", type: :request do
  let(:rsa_private_key) { OpenSSL::PKey::RSA.generate(2048) }

  after do
    StandardId::JwtService.reset_cached_key!
  end

  describe "GET /api/.well-known/jwks.json" do
    context "with symmetric algorithm (HS256)" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:hs256)
      end

      it "returns 404 not found" do
        get "/api/.well-known/jwks.json"

        expect(response).to have_http_status(:not_found)
        expect(json_body["error"]).to eq("JWKS not available")
      end
    end

    context "with asymmetric algorithm (RS256)" do
      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(rsa_private_key.to_pem)
      end

      it "returns valid JWKS JSON" do
        get "/api/.well-known/jwks.json"

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/json")

        body = json_body
        expect(body["keys"]).to be_an(Array)
        expect(body["keys"].length).to eq(1)
      end

      it "includes RSA key parameters" do
        get "/api/.well-known/jwks.json"

        key = json_body["keys"].first
        expect(key["kty"]).to eq("RSA")
        expect(key["kid"]).to be_present
        expect(key["n"]).to be_present
        expect(key["e"]).to be_present
      end

      it "does not expose private key material" do
        get "/api/.well-known/jwks.json"

        key = json_body["keys"].first
        expect(key["d"]).to be_nil
        expect(key["p"]).to be_nil
        expect(key["q"]).to be_nil
      end

      it "sets cache headers" do
        get "/api/.well-known/jwks.json"

        cache_control = response.headers["Cache-Control"]
        expect(cache_control).to include("public")
        expect(cache_control).to include("max-age=3600")
      end

      it "returned keys can verify tokens" do
        # Create a token
        allow(StandardId.config).to receive(:issuer).and_return(nil)
        token = StandardId::JwtService.encode({ sub: "user-123" })

        # Get the JWKS
        get "/api/.well-known/jwks.json"
        jwks_response = json_body

        # Verify the token using the JWKS
        jwk_set = JWT::JWK::Set.new(jwks_response)
        decoded = JWT.decode(token, nil, true, { algorithms: ["RS256"], jwks: jwk_set })

        expect(decoded.first["sub"]).to eq("user-123")
      end
    end

    context "with key rotation (multiple keys)" do
      let(:old_rsa_key) { OpenSSL::PKey::RSA.generate(2048) }

      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:rs256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(rsa_private_key.to_pem)
        allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return([old_rsa_key.to_pem])
      end

      it "returns multiple keys in JWKS" do
        get "/api/.well-known/jwks.json"

        expect(response).to have_http_status(:ok)
        expect(json_body["keys"].length).to eq(2)
      end

      it "each key has a unique kid" do
        get "/api/.well-known/jwks.json"

        kids = json_body["keys"].map { |k| k["kid"] }
        expect(kids.uniq.length).to eq(2)
      end

      it "can verify tokens signed with any listed key" do
        allow(StandardId.config).to receive(:issuer).and_return(nil)

        # Sign token with old key
        old_kid = Digest::SHA256.hexdigest(old_rsa_key.public_to_pem)[0..7]
        old_token = JWT.encode(
          { sub: "old-user", exp: 1.hour.from_now.to_i },
          old_rsa_key, "RS256", { kid: old_kid }
        )

        get "/api/.well-known/jwks.json"
        jwk_set = JWT::JWK::Set.new(json_body)

        decoded = JWT.decode(old_token, nil, true, { algorithms: ["RS256"], jwks: jwk_set })
        expect(decoded.first["sub"]).to eq("old-user")
      end
    end

    context "with cross-algorithm rotation (RS256 -> ES256)" do
      let(:old_rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
      let(:ec_private_key) { OpenSSL::PKey::EC.generate("prime256v1") }

      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:es256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(ec_private_key.to_pem)
        allow(StandardId.config.oauth).to receive(:previous_signing_keys).and_return([
          { key: old_rsa_key.to_pem, algorithm: :rs256 }
        ])
      end

      it "returns both RSA and EC keys in JWKS" do
        get "/api/.well-known/jwks.json"

        expect(response).to have_http_status(:ok)
        key_types = json_body["keys"].map { |k| k["kty"] }
        expect(key_types).to contain_exactly("EC", "RSA")
      end
    end

    context "with ES256 algorithm" do
      let(:ec_private_key) { OpenSSL::PKey::EC.generate("prime256v1") }

      before do
        allow(StandardId.config.oauth).to receive(:signing_algorithm).and_return(:es256)
        allow(StandardId.config.oauth).to receive(:signing_key).and_return(ec_private_key.to_pem)
      end

      it "returns valid JWKS JSON with EC key" do
        get "/api/.well-known/jwks.json"

        expect(response).to have_http_status(:ok)

        key = json_body["keys"].first
        expect(key["kty"]).to eq("EC")
        expect(key["crv"]).to be_present
        expect(key["x"]).to be_present
        expect(key["y"]).to be_present
      end

      it "does not expose private key material" do
        get "/api/.well-known/jwks.json"

        key = json_body["keys"].first
        expect(key["d"]).to be_nil
      end
    end
  end
end
