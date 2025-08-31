Rails.application.routes.draw do
  mount StandardId::Engine => "/"

  get "info", to: "public#info"

  namespace :backend do
    root to: "dashboard#index"
  end

  namespace :api do
    resource :ping, only: [:show]
  end
end
