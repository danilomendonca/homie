module Api
  module V1
    module InventoryItemSerializer
      module_function

      def serialize(item)
        {
          id: item.id,
          product_id: item.product_id,
          quantity: item.quantity.to_f,
          expiration_date: item.expiration_date&.iso8601,
          created_at: item.created_at.utc.iso8601,
          updated_at: item.updated_at.utc.iso8601
        }
      end
    end
  end
end
