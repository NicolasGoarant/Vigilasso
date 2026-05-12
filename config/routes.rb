Rails.application.routes.draw do
  devise_for :users, skip: [:registrations]
  root "pages#home"
  get "methodologie", to: "pages#methodologie"
  get "/qui-sommes-nous", to: "pages#qui_sommes_nous", as: :qui_sommes_nous

  get  "/analyser",  to: "analyses#new",    as: :analyser
  post "/analyser",  to: "analyses#create"
  get  "/analyse/:token",              to: "analyses#show",   as: :analyse
  post "/analyse/:token/sauvegarder",  to: "analyses#save",   as: :sauvegarder_analyse

  resources :associations, only: [:index, :show, :new, :create, :update, :destroy] do
    member do
      post :relancer_extraction
    end
    collection do
      get :export
    end
  end
end
