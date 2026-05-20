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

      # Additive bulk: groups inputs by (product_id, expiration_date) and either
      # merges into the oldest matching existing batch (update-context validators)
      # or creates a new batch (create-context validators, including past-date rule).
      # PRD §15: single-writer in v1, so no row lock — two concurrent bulks could lose updates.
      def bulk_create
        raise ActionController::ParameterMissing, :inventory_items unless params[:inventory_items].is_a?(Array)

        if params[:inventory_items].size > BULK_LIMIT
          return render status: :bad_request,
            json: { errors: [ { message: "inventory_items array exceeds maximum of #{BULK_LIMIT} items" } ] }
        end

        prepared = prepare_bulk_inputs(params[:inventory_items])

        shape_failures = collect_shape_failures(prepared)
        return render status: :unprocessable_entity, json: { failed: shape_failures } if shape_failures.any?

        groups = build_groups(prepared)

        group_failures = collect_group_failures(groups)
        return render status: :unprocessable_entity, json: { failed: group_failures } if group_failures.any?

        created_ids, updated_ids = persist_groups(groups)

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

      def collect_shape_failures(prepared)
        failures = {}
        prepared.each do |entry|
          item_errors = []
          qty = entry[:permitted][:quantity]

          if qty.nil? || (qty.respond_to?(:empty?) && qty.empty?)
            item_errors << { field: "quantity", message: "can't be blank" }
          else
            begin
              numeric = BigDecimal(qty.to_s)
              if numeric < 0
                item_errors << { field: "quantity", message: "must be greater than or equal to 0" }
              end
            rescue ArgumentError, TypeError
              item_errors << { field: "quantity", message: "is not a number" }
            end
          end

          if item_errors.any?
            failures[entry[:index]] = { index: entry[:index], input: entry[:raw], errors: item_errors }
          end
        end
        failures.values.sort_by { |f| f[:index] }
      end

      def build_groups(prepared)
        product_ids = prepared.map { |e| e[:permitted][:product_id] }.compact.uniq
        existing_by_key = {}
        if product_ids.any?
          InventoryItem.includes(:product)
            .where(product_id: product_ids)
            .order(:created_at, :id)
            .each do |item|
              key = [ item.product_id, item.expiration_date ]
              existing_by_key[key] ||= item
            end
        end

        groups_by_key = {}
        prepared.each do |entry|
          permitted = entry[:permitted]
          key = [ permitted[:product_id], normalize_date(permitted[:expiration_date]) ]
          delta = BigDecimal(permitted[:quantity].to_s)
          group = groups_by_key[key] ||= { key: key, entries: [], total_delta: BigDecimal("0") }
          group[:entries] << entry
          group[:total_delta] += delta
        end

        groups_by_key.values.map do |group|
          existing = existing_by_key[group[:key]]
          if existing
            existing.quantity = existing.quantity + group[:total_delta]
            group[:record] = existing
            group[:was_new] = false
          else
            product_id, exp_date = group[:key]
            group[:record] = InventoryItem.new(
              product_id: product_id,
              expiration_date: exp_date,
              quantity: group[:total_delta]
            )
            group[:was_new] = true
          end
          group
        end
      end

      def normalize_date(value)
        return nil if value.nil?
        return nil if value.respond_to?(:empty?) && value.empty?
        return value if value.is_a?(Date)
        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def collect_group_failures(groups)
        failures = {}
        groups.each do |group|
          record = group[:record]
          next if record.valid?

          record.errors.each do |err|
            group[:entries].each do |entry|
              bucket = failures[entry[:index]] ||= { index: entry[:index], input: entry[:raw], errors: [] }
              bucket[:errors] << { field: err.attribute.to_s, message: err.message }
            end
          end
        end
        failures.values.sort_by { |f| f[:index] }
      end

      def persist_groups(groups)
        created_ids = []
        updated_ids = []
        InventoryItem.transaction do
          groups.each do |group|
            group[:record].save!
            (group[:was_new] ? created_ids : updated_ids) << group[:record].id
          end
        end
        [ created_ids, updated_ids ]
      end
    end
  end
end
