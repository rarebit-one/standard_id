StandardId::WebEngine.routes.draw do
  scope module: :web do
    # Authentication flows
    resource :login, only: [:show, :create], controller: :login
    resource :logout, only: [:create], controller: :logout
    resource :signup, only: [:show, :create], controller: :signup

    # Social authentication callbacks (web flow)
    namespace :auth do
      post "callback_mobile/:provider", to: "callback/providers#mobile_callback", as: :callback_mobile

      namespace :callback do
        get ":provider", to: "providers#callback", as: :provider
        post ":provider", to: "providers#callback"
      end
    end

    # Password reset
    namespace :reset_password do
      resource :start, only: [:show, :create], controller: :start
      resource :confirm, only: [:show, :update], controller: :confirm
    end

    # Identifier verification (email)
    namespace :verify_email do
      resource :start, only: [:show, :create], controller: :start
      resource :confirm, only: [:show, :update], controller: :confirm
    end

    # Identifier verification (phone)
    namespace :verify_phone do
      resource :start, only: [:show, :create], controller: :start
      resource :confirm, only: [:show, :update], controller: :confirm
    end

    # Account management
    resource :account, only: [:show, :edit, :update], controller: :account
    resources :sessions, only: [:index, :destroy], controller: :sessions
  end
end
