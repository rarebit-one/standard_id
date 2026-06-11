module StandardId
  module Web
    # Renders the OAuth consent screen and records the user's decision.
    #
    # The consent screen is authenticated HTML, so it lives on the WebEngine
    # (full ERB / Inertia stack with `layout "public"`), alongside login. The
    # API authorize endpoint (ActionController::API, JSON/redirect only) hands
    # off here with a signed payload of the original /authorize params when a
    # client has require_consent enabled and no prior grant exists.
    #
    # Flow:
    #   GET  /consent?consent_request=<signed>  -> show the screen
    #   POST /consent (decision=approve|deny)   -> record + resume, or deny
    #
    # On approve we persist a ClientGrant and resume issuing the authorization
    # code by running the same AuthorizationCodeAuthorizationFlow the API
    # endpoint would have run — so redirect_uri and PKCE are revalidated here,
    # not duplicated. On deny we redirect to redirect_uri with
    # error=access_denied (+ state), per RFC 6749 §4.1.2.1.
    class ConsentController < BaseController
      public_controller

      include StandardId::InertiaRendering

      layout "public"

      skip_before_action :require_browser_session!, only: [:show, :create]

      # A bad/expired consent payload or an unknown client must not 500. The
      # WebEngine doesn't render OAuth errors as JSON (that's the API layer),
      # so surface a 400 HTML page instead.
      rescue_from StandardId::OAuthError, with: :handle_consent_error

      before_action :require_authenticated!
      before_action :load_consent_request

      def show
        @client = consent_client
        raise StandardId::InvalidClientError, "Invalid client_id" unless @client

        @scopes = scope_list
        render_with_inertia props: consent_props
      end

      def create
        @client = consent_client
        raise StandardId::InvalidClientError, "Invalid client_id" unless @client

        if params[:decision].to_s == "approve"
          approve!
        else
          deny!
        end
      end

      private

      def require_authenticated!
        return if current_account.present?

        base_login_url = StandardId.config.login_url.presence || "/login"
        separator = base_login_url.include?("?") ? "&" : "?"
        redirect_to "#{base_login_url}#{separator}redirect_uri=#{CGI.escape(request.url)}",
                    allow_other_host: true, status: :found
      end

      def load_consent_request
        @consent_request = StandardId::Oauth::ConsentPayload.decode(params[:consent_request])
        raise StandardId::InvalidRequestError, "Invalid or expired consent request" if @consent_request.blank?
      end

      def consent_client
        @consent_client ||= StandardId::ClientApplication.active.find_by(client_id: @consent_request[:client_id])
      end

      def approve!
        StandardId::ClientGrant.record!(
          account: current_account,
          client_id: @client.client_id,
          scope: @consent_request[:scope]
        )

        result = StandardId::Oauth::AuthorizationCodeAuthorizationFlow
          .new(@consent_request, request, current_account: current_account)
          .execute

        redirect_to result[:redirect_to], status: result[:status] || :found, allow_other_host: true
      end

      def deny!
        redirect_to denied_redirect_uri, status: :found, allow_other_host: true
      end

      def denied_redirect_uri
        base = @consent_request[:redirect_uri].presence || @client.redirect_uris_array.first
        params_hash = { error: "access_denied", state: @consent_request[:state] }.compact
        build_error_redirect(base, params_hash)
      end

      def build_error_redirect(base_uri, params_hash)
        uri = URI.parse(base_uri)
        query = URI.decode_www_form(uri.query || "")
        params_hash.each { |k, v| query << [k.to_s, v.to_s] if v.present? }
        uri.query = URI.encode_www_form(query)
        uri.to_s
      end

      def consent_props
        {
          client: {
            client_id: @client.client_id,
            name: @client.name,
            description: @client.description
          },
          scopes: scope_list,
          consent_request: params[:consent_request],
          flash: { notice: flash[:notice], alert: flash[:alert] }.compact
        }
      end

      def scope_list
        @consent_request[:scope].to_s.split(/\s+/).map(&:strip).reject(&:blank?)
      end

      def handle_consent_error(error)
        @consent_error = error.message
        if use_inertia?
          render inertia: inertia_component_name(:error),
                 props: { error: @consent_error }, status: :bad_request
        else
          render :error, status: :bad_request
        end
      end
    end
  end
end
