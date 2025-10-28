module StandardId
  module Oauth
    class PasswordFlow < TokenGrantFlow
      expect_params :username, :password, :client_id
      permit_params :client_secret, :audience, :scope, :realm

      def authenticate!
        validate_client_secret!(params[:client_id], params[:client_secret]) if params[:client_secret].present?

        @account = authenticate_account(params[:username], params[:password])
        raise StandardId::InvalidGrantError, "Invalid username or password" if @account.blank?

        validate_requested_scope!
      end

      private

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
        StandardId::PasswordCredential
          .includes(credential: :account)
          .find_by(login: username)
          &.authenticate(password)
          &.account
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
