module Api
  module V1
    class CategoriesController < BaseController
      before_action :set_category, only: %i[show update destroy]

      def index
        categories = Category.order(name: :asc)
        render json: categories.map { |c| CategorySerializer.serialize(c) }
      end

      def show
        render json: CategorySerializer.serialize(@category)
      end

      def create
        category = Category.create!(category_params)
        render status: :created, json: CategorySerializer.serialize(category)
      end

      def update
        @category.update!(category_params)
        render json: CategorySerializer.serialize(@category)
      end

      def destroy
        @category.destroy!
        head :no_content
      end

      private

      def set_category
        @category = Category.find(params[:id])
      end

      def category_params
        params.permit(:name)
      end
    end
  end
end
