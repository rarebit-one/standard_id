module StandardId
  module Api
    module Oauth
      class RevocationsController < BaseController
        public_controller

        skip_before_action :validate_content_type!

        # POST /oauth/revoke
        # RFC 7009 - OAuth 2.0 Token Revocation
        #
        # Accepts a token and optional token_type_hint parameter.
        # Always responds with 200 OK regardless of whether the token
        # was valid or revocation was successful (per RFC 7009 Section 2.1).
        def create
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"

          token = params[:token]
          head :ok and return if token.blank?

          payload = StandardId::JwtService.decode(token)
          head :ok and return unless payload&.dig(:sub)

          account_id = payload[:sub]

          sessions = StandardId::DeviceSession
            .where(account_id: account_id)
            .active

          revoked_sessions = sessions.to_a
          if revoked_sessions.any?
            revoked_sessions.each { |session| session.revoke!(reason: "token_revocation") }

            StandardId::Events.publish(
              StandardId::Events::OAUTH_TOKEN_REVOKED,
              account_id: account_id,
              sessions_revoked: revoked_sessions.size
            )
          end

          head :ok
        end
      end
    end
  end
end
