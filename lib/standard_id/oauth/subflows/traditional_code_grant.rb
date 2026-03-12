module StandardId
  module Oauth
    module Subflows
      class TraditionalCodeGrant < Base
        def call
          store_authorization_code

          redirect_params = {
            code: authorization_code,
            state: params[:state]
          }.compact

          redirect_url = build_redirect_uri(params[:redirect_uri], redirect_params)

          { redirect_to: redirect_url, status: :found }
        end

        private

        def authorization_code
          @authorization_code ||= SecureRandom.urlsafe_base64(32)
        end

        def store_authorization_code
          StandardId::AuthorizationCode.issue!(
            plaintext_code: authorization_code,
            client_id: params[:client_id],
            redirect_uri: params[:redirect_uri],
            scope: params[:scope],
            audience: params[:audience],
            account: params[:current_account],
            code_challenge: params[:code_challenge],
            code_challenge_method: params[:code_challenge_method],
            nonce: params[:nonce],
            metadata: { state: params[:state] }.compact
          )
        end

        def build_redirect_uri(base_uri, params_hash)
          uri = URI.parse(base_uri)
          query_params = URI.decode_www_form(uri.query || "")

          params_hash.each do |key, value|
            query_params << [key.to_s, value.to_s] if value.present?
          end

          uri.query = URI.encode_www_form(query_params)
          uri.to_s
        end
      end
    end
  end
end
