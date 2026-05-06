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

        prepared = params[:products].each_with_index.map do |attrs, index|
          wrapped = attrs.is_a?(ActionController::Parameters) ? attrs : ActionController::Parameters.new(attrs.to_h)
          permitted = wrapped.permit(:name, :brand, :notes, :category_id, :unit_type, :low_stock_threshold)
          raw_attrs = attrs.is_a?(ActionController::Parameters) ? attrs.to_unsafe_h : attrs.to_h
          [ Product.new(permitted), index, raw_attrs ]
        end

        failures = collect_bulk_failures(prepared)
        return render status: :unprocessable_entity, json: { failed: failures } if failures.any?

        Product.transaction do
          prepared.each { |product, _, _| product.save! }
        end

        ids = prepared.map { |p, _, _| p.id }
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

      def collect_bulk_failures(prepared)
        failures = {}
        seen_names = {}

        prepared.each do |product, index, raw|
          item_errors = []
          unless product.valid?
            product.errors.each do |err|
              item_errors << { field: err.attribute.to_s, message: err.message }
            end
          end

          unless product.name.blank?
            key = product.name.to_s.downcase
            if seen_names.key?(key)
              item_errors << { field: "name", message: "is duplicated within bulk request" }
            else
              seen_names[key] = index
            end
          end

          failures[index] = { index: index, input: raw, errors: item_errors } if item_errors.any?
        end

        failures.values.sort_by { |f| f[:index] }
      end
    end
  end
end
