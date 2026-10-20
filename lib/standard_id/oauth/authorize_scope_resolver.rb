module StandardId
  module Oauth
    # Applies `config.oauth.authorize_scope_resolver` to an /authorize request's
    # scope once the client and audience are known. Shared by the authorize
    # flows (what the code is issued with) and the consent gate (what the user
    # is shown, what the grant is checked against and recorded as), so the two
    # cannot disagree.
    #
    # The consent resume re-runs the flow with the already-normalised scope, so
    # a resolver must be idempotent: applying it to its own output must change
    # nothing. Collapsing, filtering and appending a default all are; an
    # append that does not check for presence is not (the Array/String output
    # is de-duplicated, which covers the common case).
    module AuthorizeScopeResolver
      module_function

      # @return [String, nil] the normalised scope (nil/blank in → nil/blank out
      #   unless the resolver answers)
      def resolve(scope:, audience:, client:, request: nil)
        custom = StandardId.config.oauth.authorize_scope_resolver
        return scope unless custom.respond_to?(:call)

        context = { scope: scope, audience: audience, client: client, request: request }
        answer = custom.call(**StandardId::Utils::CallableParameterFilter.filter(custom, context))
        case answer
        when nil then scope
        when Array then answer.map(&:to_s).reject(&:blank?).uniq.join(" ")
        when String, Symbol then answer.to_s.split.uniq.join(" ")
        else
          raise StandardId::ConfigurationError,
            "StandardId config: `oauth.authorize_scope_resolver` must return a String, Array, Symbol or nil, got #{answer.class}"
        end
      end
    end
  end
end
