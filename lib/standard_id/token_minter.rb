module StandardId
  # Mint an access token (and optionally a refresh token) for an account the
  # host has already authenticated, through the same pipeline /oauth/token
  # uses — so the claims, the audience → profile binding, the account-status
  # guards and the OAUTH_TOKEN_ISSUING / OAUTH_TOKEN_ISSUED events are the ones
  # every other token gets, instead of a hand-rolled JwtService.encode that
  # re-derives the initializer's claim resolvers by hand.
  #
  #   result = StandardId::TokenMinter.mint(
  #     account: account,
  #     audience: "harness",
  #     scopes: "profile permissions",
  #     grant_type: "harness.mint",       # free-form; lands in the JWT and the audit event
  #     claims: { permissions: scopes },  # host extras; reserved keys are dropped
  #     expires_in: 60.minutes
  #   )
  #   result.access_token  # the JWT
  #   result.jti           # what OAUTH_TOKEN_ISSUED carried
  #
  # What runs, in order: audience validation (oauth.allowed_audiences),
  # audience → profile binding (oauth.audience_profile_types, fail-closed),
  # OAUTH_TOKEN_ISSUING (AccountStatus / AccountLocking refuse here),
  # scope_claims + claim_resolvers and custom_claims, then the host's own
  # +claims+, then OAUTH_TOKEN_ISSUED. A refresh token is persisted only when
  # +refresh_token: true+, bound to +client_id+'s ClientApplication when that
  # names one. Pass +request:+ to let config.session.session_type_resolver
  # materialise a session; without it the mint is sessionless.
  #
  # Raises the same errors the token endpoint would (InvalidGrantError,
  # InvalidRequestError, NoBoundProfileError, AccountDeactivatedError, …).
  module TokenMinter
    Result = Data.define(:access_token, :refresh_token, :token_type, :expires_in, :scope, :jti, :audit_error) do
      # audit_error arrived in 0.51; optional so a host spec that builds a
      # Result to stub +mint+ keeps working.
      def initialize(audit_error: nil, **members)
        super
      end
    end

    module_function

    # @param account [ActiveRecord::Base] a persisted account
    # @param audience [String, Array<String>] the `aud` claim
    # @param grant_type [String] recorded in the JWT and the audit events
    # @param scopes [String, Array<String>, nil] the `scope` claim and the key
    #   into oauth.scope_claims
    # @param client_id [String, nil] the `client_id` claim; a registered
    #   ClientApplication's id binds the refresh token to it
    # @param claims [Hash] extra claims merged last (reserved keys dropped)
    # @param expires_in [Integer, ActiveSupport::Duration, nil] access-token
    #   lifetime; default is oauth.token_lifetimes[grant_type] or
    #   oauth.default_token_lifetime
    # @param refresh_token [Boolean] also persist and return a refresh token;
    #   requires +client_id+, which the refresh grant matches on redemption
    # @param request [ActionDispatch::Request, nil] lets session_type_resolver
    #   persist a session; resolvers see `request: nil` without it
    # @param auth_method [Symbol, String, nil] how the host authenticated the
    #   account, recorded on the refresh token for login_method_policy; nil is
    #   judged as :unspecified on refresh, which a restrictive policy refuses
    # @param auth_provider [String, nil]
    # @param profile [ActiveRecord::Base, nil] the account's profile the token
    #   is for, instead of the strict audience → profile lookup (which refuses
    #   an account holding several active profiles of the bound type). Must
    #   belong to the account, be active, and be of the bound type when the
    #   audience has a binding; claim resolvers receive it as `profile:`.
    #   oauth.audience_profile_resolver is not consulted for it — apply any
    #   gate that resolver enforces before calling.
    # @param audit_errors [Symbol] :raise (default) re-raises an
    #   OAUTH_TOKEN_ISSUED subscriber's error, as every grant does; :report
    #   logs it and returns it as +Result#audit_error+ with the token, for a
    #   caller whose contract is that an audit failure never costs it the
    #   credential. Report it to your error tracker: the gem only logs it.
    #   OAUTH_TOKEN_ISSUING (the status / locking guards) always raises.
    # @param requested_scopes [Array<String>, nil] what OAUTH_TOKEN_ISSUED
    #   reports as `requested_scopes`, for a caller whose audit trail records
    #   the permissions it granted (carried in a host claim) rather than the
    #   OAuth scope words; default (nil) is the scope words, like every grant.
    #   Changes the event only, never the token.
    # @return [Result]
    def mint(account:, audience:, grant_type:, scopes: nil, client_id: nil, claims: {}, expires_in: nil,
      refresh_token: false, request: nil, auth_method: nil, auth_provider: nil, profile: nil, audit_errors: :raise,
      requested_scopes: nil)
      flow = StandardId::Oauth::DirectMintFlow.new(
        account: account, audience: audience, grant_type: grant_type, scopes: scopes, client_id: client_id,
        claims: claims, expires_in: expires_in, refresh_token: refresh_token, request: request,
        auth_method: auth_method, auth_provider: auth_provider, profile: profile, audit_errors: audit_errors,
        requested_scopes: requested_scopes
      )
      response = flow.execute
      Result.new(
        access_token: response[:access_token],
        refresh_token: response[:refresh_token],
        token_type: response[:token_type],
        expires_in: response[:expires_in],
        scope: response[:scope],
        jti: flow.issued_jti,
        audit_error: flow.audit_error
      )
    end
  end
end
