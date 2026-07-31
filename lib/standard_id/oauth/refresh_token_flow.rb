module StandardId
  module Oauth
    class RefreshTokenFlow < TokenGrantFlow
      expect_params :refresh_token, :client_id
      permit_params :client_secret, :scope, :audience

      # authenticate! runs outside the transaction so reuse-detection
      # revocations (revoke_family!) persist even when the error propagates.
      # Only the normal rotation path (revoke old + create new) is wrapped
      # in a transaction for atomicity.
      def execute
        authenticate!
        response = nil
        StandardId::RefreshToken.transaction do
          rotate_current_refresh_token!
          response = generate_token_response
        end

        # If rotate detected a concurrent reuse (rows==0), the transaction
        # was rolled back via ActiveRecord::Rollback and response is nil.
        # Handle family revocation outside the transaction so it persists.
        handle_concurrent_reuse! unless response

        response
      end

      def authenticate!
        validate_client_secret!(params[:client_id], params[:client_secret]) if params[:client_secret].present?

        @refresh_payload = StandardId::JwtService.decode(params[:refresh_token])
        raise StandardId::InvalidGrantError, "Invalid or expired refresh_token" if @refresh_payload.blank?

        if @refresh_payload[:client_id] != params[:client_id]
          raise StandardId::InvalidGrantError, "Refresh token was not issued to this client"
        end

        validate_refresh_token_record!
        validate_scope_narrowing!
      end

      private

      def validate_refresh_token_record!
        jti = @refresh_payload[:jti]
        # Legacy tokens minted before jti tracking was added cannot be looked
        # up or revoked through the RefreshToken model. This shim can be removed
        # once all pre-jti tokens have expired (refresh_token_lifetime after deploy).
        return if jti.blank?

        # eager_load (not includes/lazy) so the parent session arrives in the
        # SAME query via a LEFT OUTER JOIN. #validate_parent_session! below
        # reads it on every refresh, and /oauth/token is a hot path — a lazy
        # `.session` would add a second SELECT per request.
        @current_refresh_token_record = StandardId::RefreshToken.eager_load(:session).find_by_jti(jti)

        unless @current_refresh_token_record
          raise StandardId::InvalidGrantError, "Refresh token not found"
        end

        if @current_refresh_token_record.revoked?
          # Reuse detected: this token was already rotated. Revoke entire family.
          @current_refresh_token_record.revoke_family!
          emit_reuse_detected_event
          raise StandardId::InvalidGrantError, "Refresh token reuse detected"
        end

        unless @current_refresh_token_record.active?
          raise StandardId::InvalidGrantError, "Refresh token is no longer valid"
        end

        validate_parent_session!
      end

      # Refuse a refresh whose parent session is no longer active.
      #
      # Without this, "revoking a session ends that session's access" was not a
      # property of the gem at all — it was an emergent consequence of every
      # caller reaching for Session#revoke! (a transaction that ALSO does
      # `refresh_tokens.active.update_all(revoked_at:)`) rather than the
      # obvious-looking `session.update!(revoked_at:)`, which revokes the
      # session row and leaves its refresh tokens live. Two apps wrote the
      # second form independently and shipped it, because a spec asserting the
      # session's own `revoked_at` passes against the buggy code.
      #
      # Checking the parent here makes the property true by construction: it
      # holds however the session was revoked — `revoke!`, a bare `update!`, a
      # bulk `update_all`, a DBA, a data fix — and it covers expiry as well.
      # See rarebit-one/rarebit-ops#297.
      #
      # A refresh token with no session (`session_id` nil) is unaffected: that
      # is the machine-to-machine shape (client_credentials and any other grant
      # the gem issues without persisting a session), where there is no parent
      # to outlive and nothing to check.
      #
      # The message is deliberately IDENTICAL to the inactive-token case above.
      # A distinct error would be an oracle: it would tell an attacker holding a
      # stolen refresh token that the token itself is still good and only the
      # session was pulled. RFC 6749 §5.2 wants `invalid_grant` either way.
      def validate_parent_session!
        session = @current_refresh_token_record.session
        return if session.nil?
        return if session.active?

        raise StandardId::InvalidGrantError, "Refresh token is no longer valid"
      end

      # Atomically revoke the current token as part of rotation.
      # Uses a conditional UPDATE to prevent TOCTOU race conditions — only one
      # concurrent request can successfully revoke and proceed.
      # Called inside a transaction with new-token creation so both succeed or
      # both roll back.
      def rotate_current_refresh_token!
        return unless @current_refresh_token_record

        rows = StandardId::RefreshToken
          .where(id: @current_refresh_token_record.id, revoked_at: nil)
          .update_all(revoked_at: Time.current)

        return if rows > 0

        # A concurrent request won the race. Roll back this transaction
        # (no new token should be issued). Reuse handling happens outside
        # the transaction in handle_concurrent_reuse! so revocations persist.
        raise ActiveRecord::Rollback
      end

      def handle_concurrent_reuse!
        @current_refresh_token_record&.reload
        if @current_refresh_token_record&.revoked?
          @current_refresh_token_record.revoke_family!
          emit_reuse_detected_event
          raise StandardId::InvalidGrantError, "Refresh token reuse detected"
        end
        raise StandardId::InvalidGrantError, "Refresh token is no longer valid"
      end

      def emit_reuse_detected_event
        StandardId::Events.publish(
          StandardId::Events::OAUTH_REFRESH_TOKEN_REUSE_DETECTED,
          account_id: @refresh_payload[:sub],
          client_id: @refresh_payload[:client_id],
          refresh_token_id: @current_refresh_token_record.id
        )
      end

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

      # Audience is bound to the refresh token - cannot be changed on refresh
      def audience
        @refresh_payload[:aud]
      end

      def refresh_token_session_id
        @current_refresh_token_record&.session_id
      end

      # Returns the (now-revoked) token record so it can be linked as
      # previous_token on the newly minted refresh token, maintaining the
      # family chain for reuse detection.
      def previous_refresh_token_record
        @current_refresh_token_record
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
