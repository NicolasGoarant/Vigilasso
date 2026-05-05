Rails.application.routes.draw do
  root "pages#home"
  get "methodologie", to: "pages#methodologie"
  resources :associations, only: [:index, :show, :new, :create, :update, :destroy] do
    member do
      post :relancer_extraction
    end
    collection do
      get :export
    end
  end
end
