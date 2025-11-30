module StandardId
  module Oauth
    class PasswordFlow < TokenGrantFlow
      expect_params :username, :password, :client_id
      permit_params :client_secret, :audience, :scope, :realm

      def authenticate!
        validate_client_secret!(params[:client_id], params[:client_secret]) if params[:client_secret].present?
        emit_authentication_started

        @account = authenticate_account(params[:username], params[:password])

        if @account.blank?
          emit_authentication_failed
          raise StandardId::InvalidGrantError, "Invalid username or password"
        end

        emit_password_validated
        validate_requested_scope!
      end

      private

      def emit_authentication_started
        StandardId::Events.publish(
          StandardId::Events::AUTHENTICATION_ATTEMPT_STARTED,
          account_lookup: params[:username],
          auth_method: "password"
        )
      end

      def emit_authentication_failed
        StandardId::Events.publish(
          StandardId::Events::AUTHENTICATION_FAILED,
          account_lookup: params[:username],
          auth_method: "password",
          error_code: "invalid_credentials",
          error_message: "Invalid username or password"
        )
      end

      def emit_password_validated
        StandardId::Events.publish(
          StandardId::Events::PASSWORD_VALIDATED,
          account: @account,
          credential_id: @credential&.id
        )
      end

      def subject_id
        @account.id
      end

      def client_id
        params[:client_id]
      end

      def token_scope
        params[:scope] || default_scope
      end

      def grant_type
        "password"
      end

      def audience
        params[:audience]
      end

      def supports_refresh_token?
        true
      end

      def authenticate_account(username, password)
        @credential = StandardId::PasswordCredential
          .includes(credential: :account)
          .find_by(login: username)

        @credential&.authenticate(password)&.account
      end

      def validate_requested_scope!
        return unless params[:scope].present?

        scope_tokens = params[:scope].split(/\s+/)
        invalid_tokens = scope_tokens.reject { |token| token.match?(/\A[a-zA-Z0-9_:-]+\z/) }

        if invalid_tokens.any?
          raise StandardId::InvalidScopeError, "Invalid scope tokens: #{invalid_tokens.join(', ')}"
        end
      end

      def default_scope
        "read"
      end

      def token_account
        @account
      end
    end
  end
end
