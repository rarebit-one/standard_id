StandardId::ApiEngine.routes.draw do
  scope module: :api do
    resource :authorize, only: [:show], controller: :authorization

    resource :userinfo, only: [:show], controller: :userinfo

    resources :sessions, only: [:index, :destroy]

    resource :passwordless, only: [], controller: :passwordless do
      post :start
    end

    namespace :oidc do
      resource :logout, only: [:show], controller: :logout
    end

    namespace :oauth do
      resource :token, only: [:create]
      resource :revoke, only: [:create], controller: :revocations

      # RFC 7591 Dynamic Client Registration -> POST /oauth/register.
      # The controller returns 404 when oauth.dynamic_registration_enabled is
      # false, so the endpoint is fully absent unless explicitly enabled.
      resource :register, only: [:create], controller: :registrations

      namespace :callback do
        post ":provider", to: "providers#callback", as: :provider
      end
    end

    scope ".well-known", module: :well_known do
      get "jwks.json", to: "jwks#show", as: :jwks
      get "openid-configuration", to: "openid_configuration#show", as: :openid_configuration
      get "oauth-authorization-server", to: "oauth_authorization_server#show", as: :oauth_authorization_server
    end
  end
end
