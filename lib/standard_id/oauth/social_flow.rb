module StandardId
  module Oauth
    class SocialFlow < TokenGrantFlow
      attr_reader :account, :connection, :original_params

      def initialize(params, request, account:, connection:, original_params: {})
        super(params, request)
        @account = account
        @connection = connection
        @original_params = original_params
      end

      def authenticate!
        raise StandardId::InvalidGrantError, "Account is required for social flow" if @account.blank?
      end

      private

      def subject_id
        @account.id
      end

      def client_id
        @original_params["client_id"]
      end

      def token_scope
        @original_params["scope"]
      end

      def grant_type
        "social"
      end

      def audience
        @original_params["audience"]
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
    end
  end
end
