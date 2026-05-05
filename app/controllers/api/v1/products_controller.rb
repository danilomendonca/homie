module Api
  module V1
    class ProductsController < BaseController
      before_action :set_product, only: %i[show update destroy]

      def index
        products = Product.all
        products = products.where(category_id: params[:category_id]) if params[:category_id].present?
        if params[:search].present?
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
          products = products.where("name ILIKE ?", pattern)
        end
        products = products.order(name: :asc)

        render json: products.map { |p| ProductSerializer.serialize(p) }
      end

      def show
        render json: ProductSerializer.serialize(@product)
      end

      def create
        product = Product.create!(product_params)
        render status: :created, json: ProductSerializer.serialize(product)
      end

      def update
        @product.assign_attributes(product_params)

        if @product.unit_type_changed? &&
           Product.unit_types.key?(@product.unit_type) &&
           @product.inventory_items.exists?
          raise Api::Conflict, "cannot change unit_type when inventory items exist"
        end

        @product.save!
        render json: ProductSerializer.serialize(@product)
      end

      def destroy
        if @product.inventory_items.where("quantity > 0").exists?
          raise Api::Conflict, "cannot delete product with active stock"
        end

        @product.destroy!
        head :no_content
      end

      private

      def set_product
        @product = Product.find(params[:id])
      end

      def product_params
        params.permit(:name, :category_id, :unit_type, :low_stock_threshold)
      end
    end
  end
end
