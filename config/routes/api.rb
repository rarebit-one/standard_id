StandardId::ApiEngine.routes.draw do
  scope module: :api do
    resource :authorize, only: [:show], controller: :authorization

    resource :userinfo, only: [:show], controller: :userinfo

    resource :passwordless, only: [], controller: :passwordless do
      post :start
    end

    namespace :oidc do
      resource :logout, only: [:show], controller: :logout
    end

    namespace :oauth do
      resource :token, only: [:create]

      namespace :callback do
        post ":provider", to: "providers#callback", as: :provider
      end
    end
  end
end
