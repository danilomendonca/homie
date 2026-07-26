module Api
  module V1
    module ProductSearchSerializer
      module_function

      # Delegates to ProductSerializer because the nested object *is* the product
      # resource — the same #/components/schemas/product the rest of the contract
      # publishes, so a new product field should surface here automatically.
      def serialize(product)
        {
          product:          ProductSerializer.serialize(product),
          similarity:       product.match_similarity.to_f.round(3),
          name_similarity:  product.name_similarity.to_f.round(3),
          brand_similarity: product.brand_similarity.to_f.round(3)
        }
      end
    end
  end
end
