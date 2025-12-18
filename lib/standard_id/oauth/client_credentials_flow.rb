module StandardId
  module Oauth
    class ClientCredentialsFlow < TokenGrantFlow
      expect_params :client_id, :client_secret, :audience
      permit_params :organization

      def authenticate!
        emit_authentication_started
        @credential = validate_client_secret!(params[:client_id], params[:client_secret])
        emit_authentication_succeeded
      rescue StandardId::InvalidClientError => e
        emit_authentication_failed(e.message)
        raise
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

      def token_client
        @credential&.client_application
      end

      def token_account
        nil
      end

      def emit_authentication_started
        StandardId::Events.publish(
          StandardId::Events::AUTHENTICATION_ATTEMPT_STARTED,
          account_lookup: params[:client_id],
          auth_method: "client_credentials"
        )
      end

      def emit_authentication_succeeded
        StandardId::Events.publish(
          StandardId::Events::AUTHENTICATION_SUCCEEDED,
          client_application: @credential&.client_application,
          auth_method: "client_credentials"
        )
      end

      def emit_authentication_failed(error_message)
        StandardId::Events.publish(
          StandardId::Events::AUTHENTICATION_FAILED,
          account_lookup: params[:client_id],
          auth_method: "client_credentials",
          error_code: "invalid_client",
          error_message: error_message
        )
      end
    end
  end
end
