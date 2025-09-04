Rails.application.routes.draw do
  mount StandardId::WebEngine => "/", as: :standard_id_web

  # Playground root
  root to: "public#info"

  get "info", to: "public#info"

  namespace :backend do
    root to: "dashboard#show"
  end

  namespace :api do
    mount StandardId::ApiEngine => "/", as: :standard_id_api

    resource :ping, only: [:show]

    namespace :v1 do
      get :protected, to: "protected#show"
    end
  end

  namespace :util do
    post "/session", to: "session#set"
  end

  get "/test_api", to: "test_api#show"

  # Demo playground namespaces
  namespace :demos do
    get "/", to: "index#show"
    get "/web", to: "web_auth#index"
    get "/social", to: "social_auth#index"
    get "/m2m", to: "m2m_auth#index"
    get "/mobile", to: "mobile_auth#index"
  end

  # Admin/management (placeholders for future UI)
  namespace :admin do
    resources :accounts, only: [:index, :show]
    resources :applications
    resources :sessions, only: [:index, :destroy]
    resources :tokens, only: [:index, :destroy]
    resources :audit_logs, only: [:index, :show]
    root to: "dashboard#index"
  end
end
