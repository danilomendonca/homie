module Api
  module V1
    module InventoryNearExpirationSerializer
      module_function

      def serialize(item)
        {
          id: item.id,
          product_id: item.product_id,
          product_name: item.product.name,
          unit_type: item.product.unit_type,
          quantity: item.quantity.to_f,
          expiration_date: item.expiration_date.iso8601
        }
      end
    end
  end
end
