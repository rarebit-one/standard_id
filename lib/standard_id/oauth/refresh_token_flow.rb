module StandardId
  module Oauth
    class RefreshTokenFlow < TokenGrantFlow
      expect_params :refresh_token, :client_id
      permit_params :client_secret, :scope, :audience

      def authenticate!
        validate_client_secret!(params[:client_id], params[:client_secret]) if params[:client_secret].present?

        @refresh_payload = StandardId::JwtService.decode(params[:refresh_token])
        raise StandardId::InvalidGrantError, "Invalid or expired refresh_token" if @refresh_payload.blank?

        if @refresh_payload[:client_id] != params[:client_id]
          raise StandardId::InvalidGrantError, "Refresh token was not issued to this client"
        end

        validate_scope_narrowing!
      end

      private

      def subject_id
        @refresh_payload[:sub]
      end

      def client_id
        @refresh_payload[:client_id]
      end

      def token_scope
        requested = params[:scope].presence
        return requested if requested.present?
        @refresh_payload[:scope]
      end

      def grant_type
        "refresh_token"
      end

      def supports_refresh_token?
        true
      end

      def validate_scope_narrowing!
        return unless params[:scope].present?

        original_scopes = Array(@refresh_payload[:scope].to_s.split(/\s+/)).reject(&:blank?)
        requested_scopes = Array(params[:scope].to_s.split(/\s+/)).reject(&:blank?)

        unless (requested_scopes - original_scopes).empty?
          raise StandardId::InvalidScopeError, "Requested scope exceeds originally granted scope"
        end

        invalid_tokens = requested_scopes.reject { |t| t.match?(/\A[a-zA-Z0-9_:-]+\z/) }
        if invalid_tokens.any?
          raise StandardId::InvalidScopeError, "Invalid scope tokens: #{invalid_tokens.join(', ')}"
        end
      end
    end
  end
end
