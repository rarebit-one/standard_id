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
        expires_in = token_expiry
        payload = build_jwt_payload(expires_in)
        access_token = StandardId::JwtService.encode(payload, expires_in: expires_in)

        response = {
          access_token: access_token,
          token_type: "Bearer",
          expires_in: expires_in.to_i
        }

        response[:scope] = token_scope if token_scope.present?
        response[:refresh_token] = generate_refresh_token if supports_refresh_token?

        response.compact
      end

      def build_jwt_payload(expires_in)
        base_payload = {
          sub: subject_id,
          client_id: client_id,
          scope: token_scope,
          grant_type: grant_type,
          aud: audience
        }.compact

        base_payload.merge(claims_from_scope_mapping)
      end

      def token_expiry
        TokenLifetimeResolver.access_token_for(token_lifetime_key)
      end

      def supports_refresh_token?
        false
      end

      def generate_refresh_token
        payload = {
          sub: subject_id,
          client_id: client_id,
          scope: token_scope,
          grant_type: "refresh_token"
        }
        StandardId::JwtService.encode(payload, expires_in: refresh_token_expiry)
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
          request: request
        }
      end

      def resolve_claim_value(resolver)
        return unless resolver.respond_to?(:call)

        filtered_context = StandardId::Utils::CallableParameterFilter.filter(resolver, claim_resolvers_context)
        resolver.call(**filtered_context)
      end
    end
  end
end
