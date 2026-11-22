StandardId::WebEngine.routes.draw do
  scope module: :web do
    # Authentication flows
    resource :login, only: [:show, :create], controller: :login

    # OAuth consent screen (authenticated HTML). The API authorize endpoint
    # hands off here with a signed payload when a client requires consent.
    resource :consent, only: [:show, :create], controller: :consent

    resource :login_verify, only: [:show, :update], controller: :login_verify
    resource :logout, only: [:create], controller: :logout

    # Step-up (recent) authentication, StandardId::StepUp. Drawn always but
    # matched only while c.step_up.enabled is true, so /step_up 404s otherwise.
    constraints(->(_request) { StandardId::StepUp.enabled? }) do
      resource :step_up, only: [:show, :create, :update], controller: :step_up
    end
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
