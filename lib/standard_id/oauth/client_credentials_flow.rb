module StandardId
  module Oauth
    class ClientCredentialsFlow < TokenGrantFlow
      expect_params :client_id, :client_secret, :audience
      permit_params :organization

      def authenticate!
        @credential = validate_client_secret!(params[:client_id], params[:client_secret])
      end

      private

      def subject_id
        @credential.client_id
      end

      def client_id
        @credential.client_id
      end

      def token_scope
        @credential.scopes
      end

      def grant_type
        "client_credentials"
      end

      def audience
        params[:audience]
      end
    end
  end
end
