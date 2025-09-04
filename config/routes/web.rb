StandardId::WebEngine.routes.draw do
  scope module: :web do
    # Authentication flows
    resource :login, only: [:show, :create], controller: :login
    resource :logout, only: [:create], controller: :logout
    resource :signup, only: [:show, :create], controller: :signup

    # Social authentication callbacks (web flow)
    namespace :auth do
      namespace :callback do
        get :google, to: "providers#google"
        post :apple, to: "providers#apple"
      end
    end

    # Password management
    resource :password, only: [], controller: :password do
      member do
        get :forgot
        post :reset_request
        get :reset
        post :reset_confirm
      end
    end

    # Account management
    resource :account, only: [:show, :edit, :update], controller: :account
    resources :sessions, only: [:index, :destroy], controller: :sessions
  end
end
