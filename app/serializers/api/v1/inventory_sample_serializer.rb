module Api
  module V1
    module InventorySampleSerializer
      module_function

      # No `batches` array, unlike the aggregate and low-stock serializers: the
      # caller is composing a chat message with a fixed number of slots, and two
      # batches differing only by expiration_date are indistinguishable on a
      # shelf — a per-batch question is unanswerable. total_quantity is the
      # currently believed count to put in the question; low_stock_threshold lets
      # the caller flag the answer without a second request.
      def serialize(product)
        {
          product_id:          product.id,
          product_name:        product.name,
          unit_type:           product.unit_type,
          total_quantity:      product.total_quantity.to_f,
          low_stock_threshold: product.low_stock_threshold&.to_f,
          stock_verified_at:   product.stock_verified_at&.utc&.iso8601
        }
      end
    end
  end
end
