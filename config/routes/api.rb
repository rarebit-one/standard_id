StandardId::ApiEngine.routes.draw do
  scope module: :api do
    resource :authorize, only: [:show], controller: :authorization

    resource :userinfo, only: [:show], controller: :userinfo

    resources :sessions, only: [:index, :destroy]

    resource :passwordless, only: [], controller: :passwordless do
      post :start
    end

    # Email + password for JSON clients (StandardId::EmailPassword). Drawn
    # always but matched only while c.email_password.enabled is true, so the
    # endpoints 404 otherwise.
    constraints(->(_request) { StandardId::EmailPassword.enabled? }) do
      scope "auth", controller: :email_password, as: :email_password do
        post "register", action: :register, as: :register
        post "login", action: :login, as: :login
        post "verify-email", action: :verify, as: :verify
        post "verify-email/resend", action: :resend, as: :resend
        post "password/forgot", action: :forgot_password, as: :forgot_password
        post "password/reset", action: :reset_password, as: :reset_password
      end
    end

    namespace :oidc do
      resource :logout, only: [:show], controller: :logout
    end

    namespace :oauth do
      resource :token, only: [:create]
      resource :revoke, only: [:create], controller: :revocations

      # RFC 7662 Token Introspection -> POST /oauth/introspect.
      # The controller returns 404 when oauth.introspection_enabled is false, so
      # the endpoint is fully absent unless explicitly enabled.
      resource :introspect, only: [:create], controller: :introspections

      # RFC 7591 Dynamic Client Registration -> POST /oauth/register.
      # The controller returns 404 when oauth.dynamic_registration_enabled is
      # false, so the endpoint is fully absent unless explicitly enabled.
      resource :register, only: [:create], controller: :registrations
      # RFC 7592 client-configuration endpoint, authenticated by the
      # registration access token issued at registration.
      get "register/:client_id", to: "registrations#show", as: :registration
      put "register/:client_id", to: "registrations#update"
      delete "register/:client_id", to: "registrations#destroy"

      namespace :callback do
        post ":provider", to: "providers#callback", as: :provider
      end
    end

    scope ".well-known", module: :well_known do
      get "jwks.json", to: "jwks#show", as: :jwks
      get "openid-configuration", to: "openid_configuration#show", as: :openid_configuration
      get "oauth-authorization-server", to: "oauth_authorization_server#show", as: :oauth_authorization_server
      # RFC 9728. The host also draws this at the origin root with
      # standard_id_protected_resource_routes, which is the URL the challenge names.
      get "oauth-protected-resource(/*resource_path)", to: "oauth_protected_resource#show",
        as: :oauth_protected_resource, format: false
    end
  end
end
