module Api
  module V1
    class ProductsController < BaseController
      BULK_LIMIT = 500

      before_action :set_product, only: %i[show update destroy]

      def index
        products = Product.includes(:category)
        products = products.where(category_id: params[:category_id]) if params[:category_id].present?
        if params[:search].present?
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
          products = products.where("name ILIKE :p OR brand ILIKE :p", p: pattern)
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

      def bulk_create
        raise ActionController::ParameterMissing, :products unless params[:products].is_a?(Array)

        if params[:products].size > BULK_LIMIT
          return render status: :bad_request,
            json: { errors: [ { message: "products array exceeds maximum of #{BULK_LIMIT} items" } ] }
        end

        products_with_index = params[:products].each_with_index.map do |attrs, index|
          wrapped = attrs.is_a?(ActionController::Parameters) ? attrs : ActionController::Parameters.new(attrs.to_h)
          permitted = wrapped.permit(:name, :brand, :notes, :category_id, :unit_type, :low_stock_threshold)
          [ Product.new(permitted), index ]
        end

        errors = collect_bulk_errors(products_with_index)
        return render status: :unprocessable_entity, json: { errors: errors } if errors.any?

        Product.transaction do
          products_with_index.each { |product, _| product.save! }
        end

        ids = products_with_index.map { |p, _| p.id }
        loaded = Product.includes(:category).where(id: ids).index_by(&:id)
        serialized = ids.map { |id| ProductSerializer.serialize(loaded[id]) }

        render status: :created, json: { created: serialized }
      end

      private

      def set_product
        @product = Product.includes(:category).find(params[:id])
      end

      def product_params
        params.permit(:name, :brand, :notes, :category_id, :unit_type, :low_stock_threshold)
      end

      def collect_bulk_errors(products_with_index)
        errors = []
        seen_names = {}

        products_with_index.each do |product, index|
          unless product.valid?
            product.errors.each do |err|
              errors << { index: index, field: err.attribute.to_s, message: err.message }
            end
          end

          next if product.name.blank?
          key = product.name.to_s.downcase
          if seen_names.key?(key)
            errors << { index: index, field: "name", message: "is duplicated within bulk request" }
          else
            seen_names[key] = index
          end
        end

        errors
      end
    end
  end
end
