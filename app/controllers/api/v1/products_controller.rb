module Api
  module V1
    class ProductsController < BaseController
      BULK_LIMIT = 500

      SEARCH_DEFAULT_MIN_SIMILARITY = 0.3
      SEARCH_DEFAULT_LIMIT = 20
      SEARCH_MAX_LIMIT = 100

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

      # The scoring itself is Product.fuzzy_search — POST /v1/inventory/import
      # resolves receipt lines with the same expressions.
      def search
        query = params[:q].to_s
        if query.strip.empty?
          raise ActionController::BadRequest, "missing or blank required query parameter `q`"
        end

        products = Product.fuzzy_search(query,
          min_similarity: parse_min_similarity(params[:min_similarity]),
          limit: parse_limit(params[:limit]))

        render json: { results: products.map { |p| ProductSearchSerializer.serialize(p) } }
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

      # Regex-then-range, as in InventoryController#parse_days: to_f/to_i on garbage
      # would silently yield 0.
      def parse_min_similarity(raw)
        return SEARCH_DEFAULT_MIN_SIMILARITY if raw.nil?

        unless raw.match?(/\A\d*\.?\d+\z/) && raw.to_f > 0 && raw.to_f <= 1
          raise ActionController::BadRequest,
            "invalid value for query parameter `min_similarity`: " \
            "must be a number greater than 0 and at most 1"
        end

        raw.to_f
      end

      def parse_limit(raw)
        return SEARCH_DEFAULT_LIMIT if raw.nil?

        unless raw.match?(/\A\d+\z/) && (1..SEARCH_MAX_LIMIT).cover?(raw.to_i)
          raise ActionController::BadRequest,
            "invalid value for query parameter `limit`: " \
            "must be an integer between 1 and #{SEARCH_MAX_LIMIT}"
        end

        raw.to_i
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
