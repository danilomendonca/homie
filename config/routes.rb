Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  scope "/v1" do
    mount Rswag::Ui::Engine => "/docs"
    mount Rswag::Api::Engine => "/api-docs"
  end

  namespace :api, path: nil do
    namespace :v1 do
      resources :categories
      resources :products do
        collection do
          post :bulk, action: :bulk_create
        end
      end
    end
  end

  match "/v1/*unmatched", to: "api/v1/base#not_found",
    via: :all, format: false
end
