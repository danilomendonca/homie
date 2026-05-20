module Api
  module V1
    module InventoryItemSerializer
      module_function

      def serialize(item)
        {
          id: item.id,
          product: {
            id: item.product.id,
            name: item.product.name,
            unit_type: item.product.unit_type,
            low_stock_threshold: item.product.low_stock_threshold&.to_f
          },
          quantity: item.quantity.to_f,
          expiration_date: item.expiration_date&.iso8601,
          created_at: item.created_at.utc.iso8601,
          updated_at: item.updated_at.utc.iso8601
        }
      end
    end
  end
end
