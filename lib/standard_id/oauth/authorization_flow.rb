module StandardId
  module Oauth
    class AuthorizationFlow < BaseRequestFlow
      attr_reader :params, :request, :current_account, :auth_lineage

      # `auth_lineage` (StandardId::AuthLineage) is how the browser session
      # behind `current_account` was established; an authorization code carries
      # it on to the tokens it is exchanged for.
      def initialize(params, request, current_account: nil, auth_lineage: nil)
        @params = params
        @request = request
        @current_account = current_account
        @auth_lineage = auth_lineage
      end

      class << self
        def extra_permitted_keys
          [:response_type]
        end
      end

      def execute
        validate_params!
        authenticate_client!
        enforce_audience_scopes!
        generate_authorization_response
      end

      private

      def validate_params!
        if params[:response_type].blank?
          raise StandardId::InvalidRequestError, "The response_type parameter is required"
        end

        if params[:client_id].blank?
          raise StandardId::InvalidRequestError, "The client_id parameter is required"
        end
      end

      def authenticate_client!
        @client = StandardId::ClientApplication.active.find_by(client_id: params[:client_id])
        unless @client
          raise StandardId::InvalidClientError, "Invalid client_id"
        end

        # TODO: support for secret key rotation
        # Maintain @client_credential for downstream compatibility (select any active secret)
        @client_credential = @client.primary_client_secret

        if params[:redirect_uri].present? && !@client.valid_redirect_uri?(params[:redirect_uri])
          raise StandardId::InvalidRequestError, "Invalid redirect_uri"
        end

        enforce_pkce_requirement!
      end

      # Hook for subclasses that participate in PKCE (authorization code
      # flows). The default implementation is a no-op so flows that cannot
      # carry a code_challenge (e.g. implicit flow) are unaffected.
      def enforce_pkce_requirement!
      end

      def generate_authorization_response
        raise NotImplementedError, "Subclasses must implement generate_authorization_response"
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

      def build_fragment_uri(base_uri, params_hash)
        uri = URI.parse(base_uri)
        fragment_params = params_hash.compact.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join("&")
        uri.fragment = fragment_params
        uri.to_s
      end

      def redirect_uri
        params[:redirect_uri] || @client&.redirect_uris_array&.first
      end

      def state
        params[:state]
      end

      # The requested scope, normalised by `oauth.authorize_scope_resolver`
      # when set (a host that collapses a scope hierarchy, or narrows a
      # request to what the chosen audience consumes, does it here instead of
      # in a shim in front of this endpoint). Resolved once, after the client
      # and audience are known; nil from the hook leaves the request as is.
      def scope
        return @scope if defined?(@scope)

        @scope = resolve_scope(params[:scope])
      end

      def resolve_scope(requested)
        custom = StandardId.config.oauth.authorize_scope_resolver
        return requested unless custom.respond_to?(:call)

        context = { scope: requested, audience: audience, client: @client, request: request }
        answer = custom.call(**StandardId::Utils::CallableParameterFilter.filter(custom, context))
        case answer
        when nil then requested
        when Array then answer.map(&:to_s).reject(&:blank?).join(" ")
        when String, Symbol then answer.to_s
        else
          raise StandardId::ConfigurationError,
            "StandardId config: `oauth.authorize_scope_resolver` must return a String, Array, Symbol or nil, got #{answer.class}"
        end
      end

      # Resolved once, after the client is known (see AudienceResolver): the
      # `audience` param, the RFC 8707 `resource`, or the client's registered
      # default. Bound to the authorization code and carried to the token.
      def audience
        return @audience if defined?(@audience)

        @audience = StandardId::Oauth::AudienceResolver.resolve(client: @client, params: params, request: request)
      end

      def resource
        params[:resource]
      end

      # `oauth.audience_scopes` is the vocabulary an audience may be asked for;
      # until now it was only ever consulted by hosts' own shims. A request for
      # a scope outside it is refused here, at /authorize, before anything is
      # issued. Unconfigured audiences (or no scope) pass through.
      def enforce_audience_scopes!
        return if audience.blank? || scope.blank?

        StandardId::Oauth::AudienceScopeResolver.assert!(requested: scope, audience: audience, client: @client)
      end
    end
  end
end
