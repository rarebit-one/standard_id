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
        get :google, to: "providers#google"
        get :google_android, to: "providers#google_android"
        get :google_ios, to: "providers#google_ios"
        post :apple, to: "providers#apple"
      end
    end
  end
end
