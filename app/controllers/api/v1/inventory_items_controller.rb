module Api
  module V1
    class InventoryItemsController < BaseController
      BULK_LIMIT = 500

      before_action :set_item, only: %i[show update destroy]

      def index
        items = InventoryItem.includes(:product)
        items = items.where(product_id: params[:product_id]) if params[:product_id].present?
        items = apply_low_stock_filter(items) if params[:low_stock] == "true"
        items = items.order(Arel.sql("inventory_items.expiration_date ASC NULLS LAST, inventory_items.created_at ASC"))

        render json: items.map { |i| InventoryItemSerializer.serialize(i) }
      end

      def show
        render json: InventoryItemSerializer.serialize(@item)
      end

      def create
        item = InventoryItem.create!(create_params)
        render status: :created, json: InventoryItemSerializer.serialize(item)
      end

      def update
        if params.key?(:product_id) && params[:product_id] != @item.product_id
          @item.errors.add(:product_id, "is immutable")
          raise ActiveRecord::RecordInvalid, @item
        end

        @item.update!(update_params)
        render json: InventoryItemSerializer.serialize(@item)
      end

      def destroy
        @item.destroy!
        head :no_content
      end

      # Bulk reset. The confirm guard is the only protection available — the API is
      # unauthenticated by design (PRD §3) and this is the one call that can empty
      # the whole inventory, so the parse is strict rather than lenient.
      def destroy_all
        unless params[:confirm] == "true"
          raise ActionController::BadRequest,
            "missing or invalid `confirm` parameter: pass confirm=true to delete inventory items"
        end

        scope = InventoryItem.all
        if params[:product_id].present?
          scope = scope.where(product_id: Product.find(params[:product_id]).id)
        end

        # delete_all, not destroy_all: InventoryItem has no callbacks and no
        # dependent associations, so one DELETE statement is sufficient.
        render json: { deleted: scope.delete_all }
      end

      # Additive bulk. The merge rule itself lives in InventoryBatchApplier so
      # POST /v1/inventory/import shares it; this action owns only the HTTP
      # surface (param permitting, limits, response envelopes).
      def bulk_create
        raise ActionController::ParameterMissing, :inventory_items unless params[:inventory_items].is_a?(Array)

        if params[:inventory_items].size > BULK_LIMIT
          return render status: :bad_request,
            json: { errors: [ { message: "inventory_items array exceeds maximum of #{BULK_LIMIT} items" } ] }
        end

        applier = InventoryBatchApplier.new(prepare_bulk_inputs(params[:inventory_items]))

        shape_failures = applier.shape_failures
        return render status: :unprocessable_entity, json: { failed: shape_failures } if shape_failures.any?

        group_failures = applier.group_failures
        return render status: :unprocessable_entity, json: { failed: group_failures } if group_failures.any?

        created_ids, updated_ids = applier.apply!

        loaded = InventoryItem.includes(:product).where(id: created_ids + updated_ids).index_by(&:id)
        render status: :created, json: {
          created: created_ids.map { |id| InventoryItemSerializer.serialize(loaded[id]) },
          updated: updated_ids.map { |id| InventoryItemSerializer.serialize(loaded[id]) }
        }
      end

      private

      def set_item
        @item = InventoryItem.includes(:product).find(params[:id])
      end

      def create_params
        params.permit(:product_id, :quantity, :expiration_date)
      end

      def update_params
        params.permit(:quantity, :expiration_date)
      end

      def apply_low_stock_filter(scope)
        totals_sql = InventoryItem.group(:product_id)
          .select(:product_id, "SUM(quantity) AS total_quantity").to_sql
        scope.joins("INNER JOIN (#{totals_sql}) agg ON agg.product_id = inventory_items.product_id")
          .joins(:product)
          .where.not(products: { low_stock_threshold: nil })
          .where("agg.total_quantity < products.low_stock_threshold")
      end

      def prepare_bulk_inputs(items)
        items.each_with_index.map do |attrs, index|
          wrapped = attrs.is_a?(ActionController::Parameters) ? attrs : ActionController::Parameters.new(attrs.to_h)
          permitted = wrapped.permit(:product_id, :quantity, :expiration_date)
          raw = attrs.is_a?(ActionController::Parameters) ? attrs.to_unsafe_h : attrs.to_h
          { index: index, raw: raw, permitted: permitted }
        end
      end
    end
  end
end
