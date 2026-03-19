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

      namespace :callback do
        post ":provider", to: "providers#callback", as: :provider
      end
    end

    scope ".well-known", module: :well_known do
      get "jwks.json", to: "jwks#show", as: :jwks
      get "openid-configuration", to: "openid_configuration#show", as: :openid_configuration
    end
  end
end
