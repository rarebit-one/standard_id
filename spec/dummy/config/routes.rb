Rails.application.routes.draw do
  # RFC 8615 clients probe the ORIGIN ROOT, which is outside any engine mount —
  # so these cannot be drawn by the gem and have to come from the host's routes
  # file. `at:` is the ApiEngine mount path below; it both builds the RFC 8414
  # §3.1 path-inserted variants and tells the resolver where endpoints live.
  standard_id_well_known_routes at: "/api"

  mount StandardId::WebEngine => "/", as: :standard_id_web

  # Playground root
  root to: "public#info"

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

  # Admin/management
  namespace :admin do
    root to: "dashboard#index"

    resources :accounts, only: [:index, :show]
    resources :clients do
      member do
        patch :rotate_secret
      end
    end
    resources :sessions, only: [:index, :destroy]
    resources :tokens, only: [:index, :destroy]
  end
end
