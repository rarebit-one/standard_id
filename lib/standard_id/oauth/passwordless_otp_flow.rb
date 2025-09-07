module StandardId
  module Oauth
    class PasswordlessOtpFlow < TokenGrantFlow
      expect_params :username, :otp, :connection, :client_id
      permit_params :client_secret, :audience, :scope

      def authenticate!
        validate_client_secret!(params[:client_id], params[:client_secret]) if params[:client_secret].present?

        raise StandardId::InvalidGrantError, "Invalid or expired verification code" if code_challenge.blank?
        raise StandardId::InvalidGrantError, "Unable to authenticate user" if account.blank?

        validate_requested_scope!

        code_challenge.use!
      end

      private

      def subject_id
        account.id
      end

      def client_id
        params[:client_id]
      end

      def token_scope
        params[:scope] || default_scope
      end

      def grant_type
        "passwordless_otp"
      end

      def audience
        params[:audience]
      end

      def supports_refresh_token?
        true
      end

      def token_expiry
        1.hour
      end

      def code_challenge
        @code_challenge ||= StandardId::CodeChallenge.active.find_by(
          realm: "authentication",
          channel: params[:connection],
          target: params[:username],
          code: params[:otp]
        )
      end

      def account
        @account ||= strategy_for(params[:connection]).find_or_create_account(params[:username])
      end

      def strategy_for(connection)
        case connection
        when "email"
          StandardId::Passwordless::EmailStrategy.new(request)
        when "sms"
          StandardId::Passwordless::SmsStrategy.new(request)
        else
          raise StandardId::InvalidRequestError, "Unsupported connection type: #{connection}"
        end
      end

      def validate_requested_scope!
        return unless params[:scope].present?

        scope_tokens = params[:scope].split(/\s+/)
        invalid_tokens = scope_tokens.reject { |token| token.match?(/\A[a-zA-Z0-9_:-]+\z/) }

        if invalid_tokens.any?
          raise StandardId::InvalidScopeError, "Invalid scope tokens: #{invalid_tokens.join(", ")}"
        end
      end

      def default_scope
        "read"
      end
    end
  end
end
