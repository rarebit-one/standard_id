module StandardId
  module Oauth
    class SocialFlow < TokenGrantFlow
      attr_reader :account, :connection, :scopes

      def initialize(params, request, account:, connection:, scopes:)
        super(params, request)
        @account = account
        @connection = connection
        @scopes = validate_and_normalize_scopes(scopes)
      end

      def authenticate!
        raise StandardId::InvalidGrantError, "Account is required for social flow" if @account.blank?
      end

      private

      def subject_id
        @account.id
      end

      def client_id
        nil
      end

      def token_scope
        scopes
      end

      def grant_type
        "social"
      end

      def supports_refresh_token?
        true
      end

      def token_lifetime_key
        :social
      end

      def token_account
        @account
      end

      def token_client
        nil
      end

      def build_jwt_payload(expires_in)
        base_payload = super(expires_in)
        base_payload.merge(provider: @connection).compact
      end

      def validate_and_normalize_scopes(scopes)
        return nil if scopes.blank?

        available_scopes = StandardId.config.social.available_scopes
        return scopes if available_scopes.blank?

        requested_scopes = scopes.to_s.split(/\s+/).reject(&:blank?).uniq
        invalid_scopes = requested_scopes - available_scopes.map(&:to_s)

        if invalid_scopes.any?
          raise StandardId::InvalidScopeError, "Invalid scope(s): #{invalid_scopes.join(', ')}. Available scopes: #{available_scopes.join(', ')}"
        end

        requested_scopes.join(" ")
      end
    end
  end
end
