module StandardId
  module Oauth
    class TokenGrantFlow < BaseRequestFlow
      attr_reader :params, :request

      def initialize(params, request, current_account: nil)
        @params = params
        @request = request
        @current_account = current_account
      end

      class << self
        def extra_permitted_keys
          [:grant_type]
        end
      end

      def execute
        authenticate!
        generate_token_response
      end

      private

      def authenticate!
        raise NotImplementedError, "Subclasses must implement authenticate!"
      end

      def validate_client_secret!(client_id, client_secret)
        client_secret_credential = StandardId::ClientSecretCredential.active.find_by(client_id: client_id)
        unless client_secret_credential&.authenticate_client_secret(client_secret)
          raise StandardId::InvalidClientError, "Client authentication failed"
        end
        client_secret_credential
      end

      def generate_token_response
        validate_audience!
        emit_token_issuing
        expires_in = token_expiry
        payload = build_jwt_payload(expires_in)
        access_token = StandardId::JwtService.encode(payload, expires_in: expires_in)

        response = {
          access_token: access_token,
          token_type: "Bearer",
          expires_in: expires_in.to_i
        }

        response[:scope] = token_scope if token_scope.present?

        # Wrap both DB writes in a single transaction so that any error
        # propagated out of maybe_persist_session_for_token! — a
        # ConfigurationError from the resolver, or a DB error from the
        # persistence layer — rolls back the refresh-token row inserted
        # above. Otherwise we'd leave an orphaned, unusable refresh token
        # the client never saw. A resolver that itself raises a non-config
        # StandardError is still logged-and-swallowed inside the helper
        # (see there for why) — that path is safe because the swallowed
        # exception fires before any DB work in this block.
        ActiveRecord::Base.transaction do
          response[:refresh_token] = generate_refresh_token if supports_refresh_token?
          maybe_persist_session_for_token!
        end

        emit_token_issued(expires_in)
        response.compact
      end

      # Give host apps a chance to persist a session for OAuth token grants
      # via `config.session.session_type_resolver`. Default resolver returns
      # nil for `:oauth_token_issued`, so this is a no-op unless the host
      # app opts in. See `StandardId::SessionTypeResolver`.
      def maybe_persist_session_for_token!
        account = token_account
        return if account.nil?

        # Only the resolver call is guarded: a buggy host-app resolver lambda
        # shouldn't torpedo the token response. Persistence errors must NOT
        # be swallowed here — we're inside an outer DB transaction, and a
        # swallowed ActiveRecord error would leave the connection's
        # transaction in an aborted state. Rails would then try to COMMIT,
        # Postgres would reject it, and the caller would receive a confusing
        # StatementInvalid instead of either a token or a clear error.
        session_class =
          begin
            StandardId::SessionTypeResolver.resolve_optional(
              request: request,
              account: account,
              flow: :oauth_token_issued
            )
          rescue StandardId::ConfigurationError
            raise
          rescue StandardError => e
            StandardId.config.logger&.error(
              "[StandardId] session_type_resolver raised during :oauth_token_issued: " \
              "#{e.class} #{e.message}"
            )
            return
          end
        return if session_class.nil?

        StandardId::Oauth::OauthSessionPersistence.persist!(
          session_class: session_class,
          account: account,
          request: request,
          audience: audience,
          grant_type: grant_type
        )
      end

      def build_jwt_payload(expires_in)
        base_payload = {
          sub: subject_id,
          client_id: client_id,
          scope: token_scope,
          grant_type: grant_type,
          aud: audience
        }.compact

        base_payload.merge(claims_from_scope_mapping).merge(claims_from_custom_claims)
      end

      def token_expiry
        TokenLifetimeResolver.access_token_for(token_lifetime_key)
      end

      def supports_refresh_token?
        false
      end

      def generate_refresh_token
        # custom_claims not included — refresh tokens carry identity only
        jti = SecureRandom.uuid
        payload = {
          sub: subject_id,
          client_id: client_id,
          scope: token_scope,
          aud: audience,
          grant_type: "refresh_token",
          jti: jti
        }.compact

        expiry = refresh_token_expiry
        # Capture expires_at once so the JWT exp and DB record are consistent
        expires_at = expiry.from_now

        # Persist the DB record first so we never hand out a signed JWT
        # that has no backing record (e.g. if the INSERT were to fail).
        persist_refresh_token!(jti: jti, expires_at: expires_at)

        StandardId::JwtService.encode(payload, expires_at: expires_at)
      end

      def persist_refresh_token!(jti:, expires_at:)
        StandardId::RefreshToken.create!(
          account_id: subject_id,
          session_id: refresh_token_session_id,
          token_digest: StandardId::RefreshToken.digest_for(jti),
          expires_at: expires_at,
          previous_token: previous_refresh_token_record
        )
      end

      def refresh_token_session_id
        nil
      end

      def previous_refresh_token_record
        nil
      end

      def refresh_token_expiry
        TokenLifetimeResolver.refresh_token_lifetime
      end

      def token_lifetime_key
        grant_type&.to_sym
      end

      def subject_id
        raise NotImplementedError
      end

      def client_id
        raise NotImplementedError
      end

      def token_scope
        raise NotImplementedError
      end

      def grant_type
        raise NotImplementedError
      end

      def audience
        params[:audience]
      end

      def validate_audience!
        allowed = StandardId.config.oauth.allowed_audiences
        return if allowed.blank? # No restriction configured
        return if audience.blank? # Audience not provided (optional)

        # aud can be string or array per JWT spec
        requested = Array(audience)
        invalid = requested - allowed

        if invalid.any?
          raise StandardId::InvalidRequestError, "Invalid audience: #{invalid.join(', ')}"
        end
      end

      def claims_from_custom_claims
        callable = StandardId.config.oauth.custom_claims
        return {} unless callable.respond_to?(:call)

        result = StandardId::Utils::CallableParameterFilter.filter(callable, claim_resolvers_context)
        claims = callable.call(**result)
        return {} unless claims.is_a?(Hash)

        # Prevent custom claims from overriding reserved JWT keys or base session fields
        claims.symbolize_keys.except(*StandardId::JwtService::RESERVED_JWT_KEYS, *StandardId::JwtService::BASE_SESSION_FIELDS)
      rescue StandardError => e
        StandardId.config.logger&.error("[StandardId] custom_claims callable raised: #{e.message}")
        {}
      end

      def claims_from_scope_mapping
        scope_claims = StandardId.config.oauth.scope_claims.with_indifferent_access
        resolvers = StandardId.config.oauth.claim_resolvers.with_indifferent_access
        return {} if scope_claims.empty? || resolvers.empty?

        claims = {}
        current_scopes.each do |scope|
          Array(scope_claims[scope]).each do |claim_key|
            next if claims.key?(claim_key)

            value = resolve_claim_value(resolvers[claim_key])
            claims[claim_key] = value unless value.nil?
          end
        end

        claims.compact.symbolize_keys
      end

      def current_scopes
        Array.wrap(token_scope)
          .flat_map { |value| value.to_s.split(/\s+/) }
          .reject(&:blank?)
          .uniq
      end

      def token_account
        return nil if subject_id.blank?

        account_class = StandardId.account_class
        return nil unless account_class.respond_to?(:find_by)

        account_class.find_by(id: subject_id)
      end

      def token_client
        StandardId::ClientApplication.find_by(client_id: client_id)
      end

      def claim_resolvers_context
        @claim_resolvers_context ||= {
          client: token_client,
          account: token_account,
          request: request,
          audience: audience
        }
      end

      def resolve_claim_value(resolver)
        filtered_context = StandardId::Utils::CallableParameterFilter.filter(resolver, claim_resolvers_context)
        resolver.call(**filtered_context)
      end

      def emit_token_issuing
        StandardId::Events.publish(
          StandardId::Events::OAUTH_TOKEN_ISSUING,
          grant_type: grant_type,
          client_id: client_id,
          account: token_account,
          scope: token_scope
        )
      end

      def emit_token_issued(expires_in)
        StandardId::Events.publish(
          StandardId::Events::OAUTH_TOKEN_ISSUED,
          grant_type: grant_type,
          client_id: client_id,
          account: token_account,
          expires_in: expires_in
        )
      end
    end
  end
end
