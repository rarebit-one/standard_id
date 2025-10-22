module StandardId
  module Oauth
    class ImplicitAuthorizationFlow < AuthorizationFlow
      expect_params :client_id
      permit_params :audience, :scope, :state, :redirect_uri, :nonce, :connection, :prompt, :organization, :invitation

      private

      def generate_authorization_response
        access_token = generate_access_token

        id_token = generate_id_token if include_id_token?

        fragment_params = {
          access_token: access_token,
          token_type: "Bearer",
          expires_in: token_expiry.to_i,
          scope: scope,
          state: state
        }

        fragment_params[:id_token] = id_token if id_token

        {
          redirect_to: build_fragment_uri(redirect_uri, fragment_params),
          status: :found
        }
      end

      def generate_access_token
        expires_in = token_expiry
        payload = build_access_token_payload(expires_in)
        StandardId::JwtService.encode(payload, expires_in: expires_in)
      end

      def generate_id_token
        return nil unless include_id_token?

        expires_in = token_expiry
        payload = build_id_token_payload(expires_in)
        StandardId::JwtService.encode(payload, expires_in: expires_in)
      end

      def include_id_token?
        params[:response_type]&.include?("id_token")
      end

      def build_access_token_payload(expires_in)
        {
          sub: subject_id,
          client_id: params[:client_id],
          scope: scope,
          aud: audience,
          iat: Time.current.to_i,
          exp: (Time.current + expires_in).to_i
        }.compact
      end

      def build_id_token_payload(expires_in)
        {
          sub: subject_id,
          aud: params[:client_id],
          iss: StandardId.config.issuer,
          iat: Time.current.to_i,
          exp: (Time.current + expires_in).to_i,
          nonce: params[:nonce]
        }.compact
      end

      def token_expiry
        TokenLifetimeResolver.access_token_for(:implicit)
      end

      def subject_id
        current_account.id
      end
    end
  end
end
