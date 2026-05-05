module Api
  module V1
    module ProductSerializer
      module_function

      def serialize(product)
        {
          id: product.id,
          name: product.name,
          category_id: product.category_id,
          unit_type: product.unit_type,
          low_stock_threshold: product.low_stock_threshold&.to_f,
          created_at: product.created_at.utc.iso8601,
          updated_at: product.updated_at.utc.iso8601
        }
      end
    end
  end
end
