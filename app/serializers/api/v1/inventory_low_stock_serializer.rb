module Api
  module V1
    module InventoryLowStockSerializer
      module_function

      def serialize(product, batches)
        {
          product_id: product.id,
          product_name: product.name,
          unit_type: product.unit_type,
          total_quantity: product.total_quantity.to_f,
          low_stock_threshold: product.low_stock_threshold.to_f,
          batches: batches.map { |b|
            {
              id: b.id,
              quantity: b.quantity.to_f,
              expiration_date: b.expiration_date&.iso8601
            }
          }
        }
      end
    end
  end
end
