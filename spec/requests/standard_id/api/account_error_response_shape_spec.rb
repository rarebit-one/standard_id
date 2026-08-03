require "rails_helper"

# One exception class, TWO wire contracts.
#
# `AccountDeactivatedError` / `AccountLockedError` are raised from the same
# subscribers (`AccountStatus` / `AccountLocking`) no matter which route was
# hit, but the correct HTTP answer depends entirely on WHAT the route is:
#
#   * a bearer-PROTECTED RESOURCE (`/api/sessions`, `/api/userinfo`) — the
#     caller PRESENTED an access token, so RFC 6750 §3.1 applies: `401`,
#     `error: "invalid_token"`, and a `WWW-Authenticate` challenge telling the
#     client to discard the token and re-authenticate.
#   * an OAuth PROTOCOL endpoint (`POST /api/oauth/token`) — the caller is
#     OBTAINING a credential, not presenting one. There is nothing to
#     challenge, and RFC 6749 §5.2 mandates a token-endpoint error object:
#     `400`, `error`, `error_description`, no `WWW-Authenticate`.
#
# 0.36.1 shipped the first contract on `Api::BaseController` and, because
# `Api::Oauth::BaseController` re-rescued only `OAuthError`, accidentally
# applied it to the second as well — the token endpoint started answering a
# bearer challenge for a request that carries no bearer token. This file pins
# both halves so neither can be "fixed" into the other again.
#
# NEGATIVE CONTROL: delete the two account `rescue_from` lines from
# StandardId::Api::Oauth::BaseController and every example under "OAuth
# protocol endpoint" must fail with a 401/invalid_token. Delete them from
# StandardId::Api::BaseController instead and every example under
# "bearer-protected resource endpoint" must fail with the raw error escaping.
RSpec.describe "Account-error response shape", type: :request do
  let(:account) do
    Account.create!(name: "Shape Test", email: "shape-#{SecureRandom.hex(4)}@example.com")
  end

  describe "bearer-protected resource endpoint (RFC 6750 §3.1)" do
    let!(:token) { bearer_jwt(account: account, scope: "openid") }
    let(:headers) { auth_headers(token) }

    # Positive control: without this, a suite that refused every request would
    # still pass the two rejection examples below.
    it "serves /api/userinfo while the account is healthy" do
      http_get "/api/userinfo", headers: headers

      expect(response).to have_http_status(:ok)
    end

    it "answers 401 invalid_token with a bearer challenge for a deactivated account" do
      account.deactivate!

      http_get "/api/userinfo", headers: headers

      expect(response).to have_http_status(:unauthorized)
      expect(json_body["error"]).to eq("invalid_token")
      expect(response.headers["WWW-Authenticate"]).to include(%(error="invalid_token"))
    end

    it "answers 401 invalid_token with a bearer challenge for a locked account" do
      account.lock!(reason: "Suspicious activity")

      http_get "/api/userinfo", headers: headers

      expect(response).to have_http_status(:unauthorized)
      expect(json_body["error"]).to eq("invalid_token")
      expect(response.headers["WWW-Authenticate"]).to include(%(error="invalid_token"))
    end
  end

  describe "OAuth protocol endpoint (RFC 6749 §5.2)" do
    let(:path) { "/api/oauth/token" }
    let(:redirect_uri) { "https://example.com/callback" }
    let(:code_verifier) { SecureRandom.urlsafe_base64(32) }

    let(:client) do
      StandardId::ClientApplication.create!(
        owner: account,
        name: "Shape Test Client",
        redirect_uris: redirect_uri,
        scopes: "openid profile email",
        grant_types: "authorization_code refresh_token",
        response_types: "code",
        client_type: "public",
        require_pkce: true,
        code_challenge_methods: "S256"
      )
    end

    def s256_challenge(verifier)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    def issue_code!
      plaintext = SecureRandom.hex(20)
      StandardId::AuthorizationCode.issue!(
        plaintext_code: plaintext,
        client_id: client.client_id,
        redirect_uri: redirect_uri,
        scope: "openid profile",
        account: account,
        code_challenge: s256_challenge(code_verifier),
        code_challenge_method: "S256"
      )
      plaintext
    end

    def redeem!(code)
      post path,
        params: {
          grant_type: "authorization_code",
          client_id: client.client_id,
          code: code,
          redirect_uri: redirect_uri,
          code_verifier: code_verifier
        },
        as: :json
    end

    def refresh!(refresh_token)
      post path,
        params: {
          grant_type: "refresh_token",
          client_id: client.client_id,
          refresh_token: refresh_token
        },
        as: :json
    end

    # Positive control for the whole describe block.
    it "mints tokens while the account is healthy" do
      redeem!(issue_code!)

      expect(response).to have_http_status(:ok)
      expect(json_body["access_token"]).to be_present
    end

    context "redeeming an authorization code (the mint leg)" do
      it "answers 400 invalid_grant for a deactivated account" do
        code = issue_code!
        account.deactivate!

        redeem!(code)

        expect(response).to have_http_status(:bad_request)
        expect(json_body["error"]).to eq("invalid_grant")
        expect(json_body["error_description"]).to be_present
        expect(json_body).not_to have_key("access_token")
      end

      it "answers 400 invalid_grant for a locked account" do
        code = issue_code!
        account.lock!(reason: "Suspicious activity")

        redeem!(code)

        expect(response).to have_http_status(:bad_request)
        expect(json_body["error"]).to eq("invalid_grant")
        expect(json_body).not_to have_key("access_token")
      end

      # The whole point of the regression: a token request must never be
      # answered with a bearer challenge. There is no token to challenge.
      it "sends no WWW-Authenticate challenge and never 401s" do
        code = issue_code!
        account.deactivate!

        redeem!(code)

        expect(response).not_to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to be_nil
        expect(json_body["error"]).not_to eq("invalid_token")
      end
    end

    context "renewing with a refresh token (the leg fundbright hit)" do
      it "answers 400 invalid_grant once the account is deactivated" do
        redeem!(issue_code!)
        expect(response).to have_http_status(:ok)
        refresh_token = json_body.fetch("refresh_token")

        account.deactivate!

        refresh!(refresh_token)

        expect(response).to have_http_status(:bad_request)
        expect(json_body["error"]).to eq("invalid_grant")
        expect(json_body).not_to have_key("access_token")
      end
    end

    # `lock_reason` is operator-authored text for logs and admin screens. It
    # must reach neither the body nor any header. More broadly, whoever
    # presented this grant may not be its legitimate holder, so the response
    # must not confirm account state at all.
    context "disclosure" do
      it "does not leak lock_reason or account state for a locked account" do
        code = issue_code!
        account.lock!(reason: "Suspicious activity")

        redeem!(code)

        expect(response.body).not_to include("Suspicious activity")
        expect(response.headers.to_h.values.grep(String).join(" ")).not_to include("Suspicious activity")
        expect(json_body["error_description"]).not_to match(/lock|suspend|deactivat|disabl/i)
      end

      # Both states render the SAME generic RFC 6749 sentence, so the response
      # cannot be used to distinguish "deactivated" from "locked" either.
      it "renders the same generic description for both account states" do
        generic = "The provided authorization grant is invalid, expired or revoked"

        code = issue_code!
        account.deactivate!
        redeem!(code)
        expect(json_body["error_description"]).to eq(generic)
      end

      it "renders that same generic description when the account is locked" do
        generic = "The provided authorization grant is invalid, expired or revoked"

        code = issue_code!
        account.lock!(reason: "Suspicious activity")
        redeem!(code)
        expect(json_body["error_description"]).to eq(generic)
      end
    end
  end

  # The structural claim that makes the split work at all: Rails resolves
  # rescue_from handlers most-recently-registered-first, and a subclass
  # registers after its parent. Both classes must therefore carry their OWN
  # registration for these errors — the OAuth subclass's wins on OAuth routes,
  # the parent's still governs every other API route. Removing either one is a
  # silent contract change, which is exactly how 0.36.1 shipped.
  describe "handler registration" do
    # `rescue_handlers` is a class_attribute, so the OAuth subclass's array
    # already CONTAINS the parent's entries — merely asserting inclusion there
    # would pass with the fix reverted. What matters is which registration wins,
    # i.e. the LAST one for each class.
    def winning_handler(controller, error_class)
      controller.rescue_handlers.reverse.find { |klass, _| klass == error_class }&.last
    end

    it "resolves the account errors to the bearer handlers on the plain API base" do
      expect(winning_handler(StandardId::Api::BaseController, "StandardId::AccountDeactivatedError"))
        .to eq(:handle_account_deactivated)
      expect(winning_handler(StandardId::Api::BaseController, "StandardId::AccountLockedError"))
        .to eq(:handle_account_locked)
    end

    it "resolves them to the OAuth handler on the OAuth base, overriding the parent" do
      expect(winning_handler(StandardId::Api::Oauth::BaseController, "StandardId::AccountDeactivatedError"))
        .to eq(:handle_account_unusable)
      expect(winning_handler(StandardId::Api::Oauth::BaseController, "StandardId::AccountLockedError"))
        .to eq(:handle_account_unusable)
    end
  end
end
