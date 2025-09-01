StandardId::WebEngine.routes.draw do
  resource :login, only: [:show], controller: :login
end
