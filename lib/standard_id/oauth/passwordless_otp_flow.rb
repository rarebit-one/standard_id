module StandardId
  module Oauth
    class PasswordlessOtpFlow < TokenGrantFlow
      expect_params :username, :otp, :connection, :client_id
      permit_params :client_secret, :audience, :scope

      def authenticate!
        validate_client_secret!(params[:client_id], params[:client_secret]) if params[:client_secret].present?

        if code_challenge.blank?
          emit_otp_validation_failed
          raise StandardId::InvalidGrantError, "Invalid or expired verification code"
        end

        if account.blank?
          raise StandardId::InvalidGrantError, "Unable to authenticate user"
        end

        validate_requested_scope!

        code_challenge.use!
        emit_otp_validated
      end

      private

      def emit_otp_validated
        StandardId::Events.publish(
          StandardId::Events::OTP_VALIDATED,
          account: account,
          channel: params[:connection]
        )
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_VERIFIED,
          code_challenge: code_challenge,
          account: account,
          channel: params[:connection]
        )
      end

      def emit_otp_validation_failed
        StandardId::Events.publish(
          StandardId::Events::OTP_VALIDATION_FAILED,
          identifier: params[:username],
          channel: params[:connection],
          attempts: nil
        )
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_FAILED,
          identifier: params[:username],
          channel: params[:connection],
          attempts: nil
        )
      end

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

      def token_account
        account
      end
    end
  end
end
