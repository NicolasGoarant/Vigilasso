Rails.application.routes.draw do
  root "associations#index"
  resources :associations, only: [:index, :show, :new, :create, :update, :destroy] do
    member do
      post :relancer_extraction
    end
    collection do
      get :export
    end
  end
end
