module StandardId
  module Api
    module Oauth
      # RFC 7662 OAuth 2.0 Token Introspection (POST /oauth/introspect).
      #
      # Off by default. The endpoint is fully absent (404) unless
      # `StandardId.config.oauth.introspection_enabled` is true, mirroring how
      # `dynamic_registration_enabled` gates `/oauth/register`: an endpoint that
      # answers questions about other people's tokens is not something to expose
      # by accident.
      #
      # Confidential clients only (RFC 7662 §2.1 requires the caller be
      # authorized). Credentials arrive as HTTP Basic or in the form body, per
      # RFC 6749 §2.3.1 — never both.
      #
      # Every failure mode renders `{"active": false}` with **no other members**,
      # per RFC 7662 §2.2. That includes bad client credentials, a blank token,
      # a garbage token, a revoked token, and a tripped rate limit. The endpoint
      # deliberately reveals nothing beyond that one bit.
      #
      # ## What introspection can and cannot tell you here
      #
      # **Read this before building an authorization gate on it.**
      #
      # Access tokens are stateless: this engine never persists them and they
      # carry no `sid`, so there is nothing to look up. A revoked session's
      # access token therefore introspects as **`active: true` until its `exp`**.
      # Introspection of an access token answers "was this minted by us, and is
      # it unexpired?" — not "is it still honoured?". The only mitigation is a
      # short `access_token_lifetime`; a caller who assumes otherwise will build
      # a gate that keeps honouring revoked credentials for a full token
      # lifetime.
      #
      # Refresh tokens ARE persisted (as `SHA256(jti)`), so those are checked
      # against the row AND against the parent session: a refresh token that is
      # itself revoked or expired — or whose session is — introspects as
      # inactive, correctly and immediately. That second half matters because
      # the session can be revoked without the cascade ever running (a bare
      # `update!`, a bulk `update_all`); see Oauth::RefreshTokenFlow and
      # rarebit-one/rarebit-ops#297.
      class IntrospectionsController < BaseController
        public_controller

        skip_before_action :validate_content_type!, raise: false

        # The `with:` renders `{active: false}` / 200 — NEVER 429. THIS IS
        # DELIBERATE; DO NOT "FIX" IT.
        #
        # A 429 distinguishes "you are throttled" from "that token is not
        # valid", which turns the rate limiter into a token-validity oracle: an
        # attacker probes until throttled, then reads the *status code* rather
        # than the body to classify tokens. Returning the ordinary inactive
        # response keeps a throttled probe indistinguishable from a miss.
        #
        # Passing an explicit `with:` also opts out of
        # RateLimitHandling.rate_limit's wrapper (which raises
        # ActionController::TooManyRequests to attach Retry-After) — that is the
        # intent, and the concern documents the opt-out.
        #
        # Keyed on `request.remote_ip`, and this matters:
        #
        #   * NOT Rack's `request.ip`, which resolves the forwarding chain
        #     against Rack's own trusted-proxy list rather than
        #     `config.action_dispatch.trusted_proxies`. Behind a CDN that returns
        #     the edge address and collapses every caller in the world into a
        #     single bucket.
        #   * NOT the `Authorization` header or client_id. `rate_limit` is a
        #     before_action, so it runs BEFORE client authentication — at that
        #     point the header is unverified, attacker-controlled input, and a
        #     caller could mint a fresh bucket per request by rotating it. The
        #     limit would evaporate exactly when it is needed.
        rate_limit to: StandardId.config.rate_limits.introspection_per_ip,
                   within: 15.minutes,
                   name: "introspection-ip",
                   by: -> { request.remote_ip },
                   with: -> { render_inactive },
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        before_action :require_introspection_enabled!

        # POST /oauth/introspect
        def create
          return render_inactive if authenticate_client!.nil?

          token = params[:token].to_s
          return render_inactive if token.blank?

          payload = decode_token(token)
          return render_inactive if payload.nil?

          # Persisted refresh tokens are checkable; access tokens are not.
          #
          # eager_load the parent session in the same query: the answer must
          # match what Oauth::RefreshTokenFlow would do with the same token, and
          # that flow refuses a refresh whose session is revoked or expired
          # (rarebit-one/rarebit-ops#297). Reporting `active: true` here for a
          # token /oauth/token would refuse would make introspection an
          # authority that disagrees with the endpoint it describes.
          #
          # A nil session means no parent — the machine-to-machine shape — and
          # is not a reason to call the token inactive.
          if payload[:jti].present?
            persisted = StandardId::RefreshToken.eager_load(:session).find_by_jti(payload[:jti].to_s)
          end
          return render_inactive if persisted && !persisted.active?
          return render_inactive if persisted&.session && !persisted.session.active?

          render json: active_response(payload, persisted), status: :ok
        end

        private

        # 404 (not 403) when the feature is off, so the endpoint is
        # indistinguishable from one that does not exist.
        def require_introspection_enabled!
          head(:not_found) unless StandardId.config.oauth.introspection_enabled
        end

        # @return [StandardId::ClientSecretCredential, nil]
        def authenticate_client!
          client_id, client_secret = client_credentials
          return nil if client_id.blank? || client_secret.blank?

          credential = StandardId::ClientSecretCredential.active.find_by(client_id: client_id)
          return nil unless credential&.authenticate_client_secret(client_secret)

          credential
        end

        # RFC 6749 §2.3.1 — Basic auth OR request body, never both. Unlike the
        # token endpoint (which raises InvalidRequestError so a misconfigured
        # client gets told), sending both here is just another `active: false`:
        # this endpoint reports nothing but that one bit.
        def client_credentials
          header = request.headers["Authorization"]
          return [params[:client_id].to_s, params[:client_secret].to_s] unless header&.start_with?("Basic ")
          return [nil, nil] if params[:client_id].present? || params[:client_secret].present?

          decoded = Base64.strict_decode64(header.split(" ", 2).last)
          id, secret = decoded.split(":", 2)
          [CGI.unescape(id.to_s), CGI.unescape(secret.to_s)]
        rescue ArgumentError
          [nil, nil]
        end

        # JwtService.decode already returns nil for malformed tokens, bad
        # signatures, expired tokens, wrong issuer and bad iat. No
        # allowed_audiences is passed: introspection is audience-agnostic and
        # returns `aud` for the caller to inspect. The rescue is
        # defence-in-depth in case that contract shifts.
        def decode_token(token)
          StandardId::JwtService.decode(token)
        rescue StandardId::InvalidAudienceError, StandardId::InvalidTokenError, JWT::DecodeError
          nil
        end

        # RFC 7662 §2.2. `.compact` so absent claims are omitted rather than
        # emitted as null.
        def active_response(payload, persisted)
          {
            active: true,
            token_type: persisted ? "refresh_token" : "Bearer",
            sub: payload[:sub],
            aud: payload[:aud],
            iss: payload[:iss],
            exp: payload[:exp],
            iat: payload[:iat],
            jti: payload[:jti],
            client_id: payload[:client_id],
            scope: payload[:scope]
          }.compact
        end

        def render_inactive
          render json: { active: false }, status: :ok
        end
      end
    end
  end
end
