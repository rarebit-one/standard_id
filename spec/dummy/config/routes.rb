Rails.application.routes.draw do
  mount StandardId::WebEngine => "/", as: :standard_id_web

  get "info", to: "public#info"

  namespace :backend do
    root to: "dashboard#show"
  end

  namespace :api do
    mount StandardId::ApiEngine => "/"

    resource :ping, only: [:show]
  end

  # Utility routes for testing
  namespace :util do
    post "/session", to: "session#set"
  end
end
