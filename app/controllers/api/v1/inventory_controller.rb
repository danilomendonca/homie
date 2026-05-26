module Api
  module V1
    class InventoryController < BaseController
      def index
        include_empty = ActiveModel::Type::Boolean.new.cast(params[:include_empty]) || false

        scope = Product
          .left_outer_joins(:inventory_items)
          .group("products.id")
          .select("products.*, COALESCE(SUM(inventory_items.quantity), 0) AS total_quantity")
          .order(Arel.sql(%(products.name COLLATE "pt-x-icu" ASC)))

        scope = scope.having("COALESCE(SUM(inventory_items.quantity), 0) > 0") unless include_empty

        products = scope.to_a

        batches_by_product = InventoryItem
          .where(product_id: products.map(&:id))
          .order(Arel.sql("expiration_date ASC NULLS LAST, created_at ASC"))
          .group_by(&:product_id)

        render json: products.map { |p|
          InventoryAggregateSerializer.serialize(p, batches_by_product[p.id] || [])
        }
      end

      def low_stock
        products = Product
          .left_outer_joins(:inventory_items)
          .where.not(low_stock_threshold: nil)
          .group("products.id")
          .select("products.*, COALESCE(SUM(inventory_items.quantity), 0) AS total_quantity")
          .having("COALESCE(SUM(inventory_items.quantity), 0) < products.low_stock_threshold")
          .order(Arel.sql(
            "COALESCE(SUM(inventory_items.quantity), 0) / products.low_stock_threshold ASC, " \
            'products.name COLLATE "pt-x-icu" ASC'
          ))
          .to_a

        batches_by_product = InventoryItem
          .where(product_id: products.map(&:id))
          .order(Arel.sql("expiration_date ASC NULLS LAST, created_at ASC"))
          .group_by(&:product_id)

        render json: products.map { |p|
          InventoryLowStockSerializer.serialize(p, batches_by_product[p.id] || [])
        }
      end
    end
  end
end
