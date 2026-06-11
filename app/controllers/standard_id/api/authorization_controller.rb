module StandardId
  module Api
    class AuthorizationController < BaseController
      public_controller

      include ActionController::Cookies

      skip_before_action :validate_content_type!

      before_action :redirect_to_login, if: :requires_authentication?

      FLOW_STRATEGIES = {
        "code" => StandardId::Oauth::AuthorizationCodeAuthorizationFlow,
        "token" => StandardId::Oauth::ImplicitAuthorizationFlow,
        "token id_token" => StandardId::Oauth::ImplicitAuthorizationFlow
      }.freeze

      def show
        reject_invalid_redirect_uri!
        return redirect_to_consent if consent_required?

        response_data = flow_strategy_class.new(flow_strategy_params, request, current_account: current_account).execute

        if response_data[:redirect_to]
          redirect_to response_data[:redirect_to], status: response_data[:status] || :found, allow_other_host: true
        else
          render json: response_data, status: :ok
        end
      end

      private

      # Validate redirect_uri against the resolved client BEFORE any consent
      # hand-off. The authorization flow validates it during #execute, but the
      # consent gate (redirect_to_consent) runs first — so without this an
      # unvalidated redirect_uri would be signed into the consent payload and the
      # Deny path would redirect straight to it (open redirect). Per OAuth, an
      # invalid redirect_uri is surfaced as an error, never redirected to. On the
      # non-consent path the flow re-validates (harmless, same error).
      def reject_invalid_redirect_uri!
        return if params[:redirect_uri].blank?

        client = consent_client
        return if client.nil? # unknown/inactive client is rejected by the flow

        return if client.valid_redirect_uri?(params[:redirect_uri])

        raise StandardId::InvalidRequestError, "Invalid redirect_uri"
      end

      # An interactive authorization-code request needs a consent screen when:
      #   * the user is authenticated,
      #   * the request is an interactive (HTML) request — not JSON, not a
      #     social-login redirect (which bounces to the provider),
      #   * the resolved client has require_consent enabled, and
      #   * the account has not already granted consent covering the scope.
      # Implicit flows and JSON callers are unaffected. The consent screen is
      # authenticated HTML, so it is rendered by the WebEngine (full ERB /
      # Inertia stack); the API endpoint hands off via a signed payload and
      # resumes here once a grant exists.
      def consent_required?
        return false unless response_type == "code"
        return false unless request.format.html?
        return false if social_login?
        return false if current_account.blank?

        client = consent_client
        return false unless client&.require_consent?

        !StandardId::ClientGrant.granted?(
          account: current_account,
          client_id: client.client_id,
          requested_scope: params[:scope]
        )
      end

      def consent_client
        @consent_client ||= StandardId::ClientApplication.active.find_by(client_id: params[:client_id])
      end

      def redirect_to_consent
        payload = StandardId::Oauth::ConsentPayload.encode(authorize_params_for_resume)
        base = StandardId.config.login_url.present? ? consent_base_from_login_url : "/consent"
        redirect_to "#{base}?consent_request=#{CGI.escape(payload)}", allow_other_host: true, status: :found
      end

      # Derive the WebEngine consent path from the configured login_url so the
      # consent screen lands on the same host/mount as login (login and consent
      # are both WebEngine, authenticated-HTML routes).
      def consent_base_from_login_url
        login = StandardId.config.login_url.to_s
        login.sub(%r{/login/?\z}, "/consent").then { |u| u == login ? "/consent" : u }
      end

      # The exact params required to resume authorization-code issuance after
      # approval. Carried through a signed payload so they cannot be tampered
      # with; redirect_uri + PKCE are revalidated when the flow re-runs.
      def authorize_params_for_resume
        {
          response_type: response_type,
          client_id: params[:client_id],
          redirect_uri: params[:redirect_uri],
          scope: params[:scope],
          audience: params[:audience],
          state: params[:state],
          code_challenge: params[:code_challenge],
          code_challenge_method: params[:code_challenge_method],
          nonce: params[:nonce]
        }.compact
      end

      def response_type
        @response_type ||= params[:response_type]
      end

      def flow_strategy_class
        @flow_strategy_class ||= begin
          if response_type.blank?
            raise StandardId::InvalidRequestError, "The response_type parameter is required"
          end

          klass = FLOW_STRATEGIES[response_type]
          unless klass
            raise StandardId::UnsupportedResponseTypeError, "Unsupported response_type: #{response_type}"
          end
          klass
        end
      end

      def flow_strategy_params
        @flow_strategy_params ||= expect_and_permit!(flow_strategy_class.expected_params, flow_strategy_class.permitted_params)
      end

      def requires_authentication?
        FLOW_STRATEGIES.key?(response_type) && !social_login?
      end

      def social_login?
        params[:connection].present?
      end

      def redirect_to_login
        return if current_account.present?

        base_login_url = StandardId.config.login_url.presence || "/login"
        separator = base_login_url.include?("?") ? "&" : "?"
        login_url = "#{base_login_url}#{separator}redirect_uri=#{CGI.escape(request.url)}"

        redirect_to login_url, allow_other_host: true, status: :found
      end

      def current_account
        @current_account ||= begin
          token_manager = StandardId::Web::TokenManager.new(request)
          session_manager = StandardId::Web::SessionManager.new(token_manager, request: request, session: session, cookies: cookies)
          session_manager.current_account
        end
      end
    end
  end
end
