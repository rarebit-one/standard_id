require "rails_helper"

# RFC 7662 Token Introspection behind a default-off toggle.
RSpec.describe "StandardId::Api::Oauth::IntrospectionsController", type: :request do
  let(:path) { "/api/oauth/introspect" }

  let(:account) { Account.create!(name: "Introspect Owner", email: "intro-#{SecureRandom.hex(4)}@example.com") }
  let(:client) do
    StandardId::ClientApplication.create!(
      owner: account, name: "Introspecting Client", redirect_uris: "https://app.example.com/cb"
    )
  end
  let(:client_secret) { "s3cret-#{SecureRandom.hex(8)}" }
  let!(:credential) do
    StandardId::ClientSecretCredential.create!(
      name: "introspector", client_secret: client_secret, client_application: client
    )
  end

  def enable_introspection!(enabled: true)
    allow(StandardId.config.oauth).to receive(:introspection_enabled).and_return(enabled)
  end

  # JwtService.encode ALWAYS overwrites :exp, so an expiry has to go through its
  # `expires_at:` kwarg rather than the payload.
  def issue_token(expires_at: 1.hour.from_now, **claims)
    StandardId::JwtService.encode({
      sub: account.id,
      aud: "api",
      client_id: credential.client_id,
      scope: "openid profile",
      jti: SecureRandom.uuid
    }.merge(claims), expires_at: expires_at)
  end

  def credentials_params
    { client_id: credential.client_id, client_secret: client_secret }
  end

  def basic_auth_header(id = credential.client_id, secret = client_secret)
    { "Authorization" => "Basic #{Base64.strict_encode64("#{id}:#{secret}")}" }
  end

  describe "the default-off toggle" do
    it "returns 404 when introspection is disabled, so the endpoint is indistinguishable from absent" do
      enable_introspection!(enabled: false)

      post path, params: credentials_params.merge(token: issue_token)

      expect(response).to have_http_status(:not_found)
    end

    it "is disabled by default, with no stubbing at all" do
      expect(StandardId.config.oauth.introspection_enabled).to be_falsey
    end
  end

  context "when introspection is enabled" do
    before { enable_introspection! }

    it "reports an active token with the RFC 7662 members" do
      post path, params: credentials_params.merge(token: issue_token)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["active"]).to be true
      expect(body["sub"].to_s).to eq(account.id.to_s)
      expect(body["aud"]).to eq("api")
      expect(body["client_id"]).to eq(credential.client_id)
      expect(body["scope"]).to eq("openid profile")
      expect(body["exp"]).to be_a(Integer)
      expect(body["token_type"]).to eq("Bearer")
    end

    it "accepts client credentials via HTTP Basic" do
      post path, params: { token: issue_token }, headers: basic_auth_header

      expect(response.parsed_body["active"]).to be true
    end

    describe "the inactive response" do
      # RFC 7662 §2.2 — when active is false, NO other members may be present.
      # Every failure mode collapses to that one bit.
      def expect_bare_inactive
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq({ "active" => false })
      end

      it "for a bad client secret" do
        post path, params: credentials_params.merge(client_secret: "wrong", token: issue_token)
        expect_bare_inactive
      end

      it "for an unknown client_id" do
        post path, params: credentials_params.merge(client_id: "nope", token: issue_token)
        expect_bare_inactive
      end

      it "for a revoked client credential" do
        credential.revoke!
        post path, params: credentials_params.merge(token: issue_token)
        expect_bare_inactive
      end

      it "for missing client credentials" do
        post path, params: { token: issue_token }
        expect_bare_inactive
      end

      it "when credentials are sent BOTH in Basic and the body (RFC 6749 §2.3.1)" do
        post path, params: credentials_params.merge(token: issue_token), headers: basic_auth_header
        expect_bare_inactive
      end

      it "for malformed Basic encoding" do
        post path, params: { token: issue_token }, headers: { "Authorization" => "Basic !!!not-base64!!!" }
        expect_bare_inactive
      end

      it "for a blank token" do
        post path, params: credentials_params.merge(token: "")
        expect_bare_inactive
      end

      it "for a garbage token" do
        post path, params: credentials_params.merge(token: "not.a.jwt")
        expect_bare_inactive
      end

      it "for an expired token" do
        post path, params: credentials_params.merge(token: issue_token(expires_at: 1.hour.ago))
        expect_bare_inactive
      end

      it "for a token signed with the wrong key" do
        foreign = JWT.encode({ sub: account.id, exp: 1.hour.from_now.to_i }, "some-other-secret", "HS256")
        post path, params: credentials_params.merge(token: foreign)
        expect_bare_inactive
      end
    end

    describe "refresh tokens (the part that IS revocation-aware)" do
      let(:session) do
        StandardId::DeviceSession.create!(
          account: account, device_id: "d-#{SecureRandom.hex(4)}",
          device_agent: "App/1.0", expires_at: 30.days.from_now
        )
      end
      let(:jti) { SecureRandom.uuid }
      let!(:refresh_token) do
        StandardId::RefreshToken.create!(
          account: account, session: session,
          token_digest: StandardId::RefreshToken.digest_for(jti),
          expires_at: 30.days.from_now
        )
      end

      it "reports an active refresh token, tagged as such" do
        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        body = response.parsed_body
        expect(body["active"]).to be true
        expect(body["token_type"]).to eq("refresh_token")
      end

      it "reports a REVOKED refresh token as inactive, immediately" do
        refresh_token.revoke!

        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        expect(response.parsed_body).to eq({ "active" => false })
      end

      it "reports an expired refresh-token row as inactive even if the JWT has not expired" do
        refresh_token.update!(expires_at: 1.hour.ago)

        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        expect(response.parsed_body).to eq({ "active" => false })
      end

      it "reports inactive once the whole session is bulk-revoked (the cascade reaches the row)" do
        StandardId::Session.revoke_all_for!(account, reason: "password_reset")

        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        expect(response.parsed_body).to eq({ "active" => false })
      end

      # The answer here must match what /oauth/token would do with the same
      # token. RefreshTokenFlow refuses a refresh whose session is revoked or
      # expired HOWEVER it was revoked (rarebit-one/rarebit-ops#297) — including
      # the forms that never run the cascade, so the token row itself stays
      # clean. Introspection has to see the same thing, or it becomes an
      # authority that disagrees with the endpoint it describes.
      it "reports inactive when the session was revoked WITHOUT the cascade (bare update!)" do
        session.update!(revoked_at: Time.current)
        expect(refresh_token.reload.revoked_at).to be_nil

        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        expect(response.parsed_body).to eq({ "active" => false })
      end

      it "reports inactive when the session was revoked WITHOUT the cascade (bulk update_all)" do
        StandardId::Session.where(id: session.id).update_all(revoked_at: Time.current)
        expect(refresh_token.reload.revoked_at).to be_nil

        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        expect(response.parsed_body).to eq({ "active" => false })
      end

      it "reports inactive when the parent session has merely expired" do
        StandardId::Session.where(id: session.id).update_all(expires_at: 1.hour.ago)

        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        expect(response.parsed_body).to eq({ "active" => false })
      end

      it "still reports active for a refresh token with no parent session" do
        refresh_token.update!(session: nil)

        post path, params: credentials_params.merge(token: issue_token(jti: jti))

        expect(response.parsed_body["active"]).to be true
      end
    end

    # This is the documented, unavoidable limit. It is asserted rather than
    # merely written down, so nobody "fixes" the docs to claim otherwise.
    describe "the honest limit: access tokens are stateless" do
      it "still reports an access token active after its session is revoked" do
        session = StandardId::DeviceSession.create!(
          account: account, device_id: "d-#{SecureRandom.hex(4)}",
          device_agent: "App/1.0", expires_at: 30.days.from_now
        )
        access_token = issue_token
        session.revoke!

        post path, params: credentials_params.merge(token: access_token)

        expect(response.parsed_body["active"]).to be(true),
          "access tokens are not persisted and carry no sid, so revocation cannot be " \
          "detected here. If this ever fails, the honest-limit docs must be updated too."
      end
    end
  end

  describe "rate limiting" do
    before { enable_introspection! }

    # A 429 would distinguish "throttled" from "token invalid" and turn the
    # limiter into a token-validity oracle. It must render the ordinary inactive
    # response instead.
    # The macro reads the limit at class-load time, so stubbing the config here
    # would be a no-op — trip the real configured limit against a stubbed store.
    let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
        .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
    end

    it "renders {active: false} with 200 rather than 429 when tripped" do
      limit = StandardId.config.rate_limits.introspection_per_ip

      (limit + 1).times { post path, params: credentials_params.merge(token: issue_token) }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ "active" => false })
      expect(response.headers["Retry-After"]).to be_nil
    end

    it "leaves a valid token introspectable below the limit" do
      post path, params: credentials_params.merge(token: issue_token)

      expect(response.parsed_body["active"]).to be true
    end
  end

  describe "discovery advertisement" do
    # The well-known controllers return 404 without a configured issuer.
    before { allow(StandardId.config).to receive(:issuer).and_return("https://auth.example.com") }

    it "advertises introspection_endpoint only when enabled" do
      enable_introspection!(enabled: false)
      get "/api/.well-known/oauth-authorization-server"
      expect(response.parsed_body).not_to have_key("introspection_endpoint")

      enable_introspection!
      get "/api/.well-known/oauth-authorization-server"
      expect(response.parsed_body["introspection_endpoint"]).to end_with("/oauth/introspect")
    end
  end
end
