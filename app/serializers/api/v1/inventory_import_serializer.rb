module Api
  module V1
    module InventoryImportSerializer
      module_function

      # `applied` is false on a dry run, and then nothing was written — so every
      # inventory_item and every created product is null rather than an id that
      # would 404 on the very next request. The fields exist unconditionally in
      # both modes so the response shape is stable and committee validates one
      # schema.
      def serialize(applied:, matched:, created:, unmatched:)
        {
          applied:   applied,
          matched:   matched.map { |entry| matched_entry(entry, applied) },
          created:   created.map { |entry| created_entry(entry, applied) },
          unmatched: unmatched.map { |entry| unmatched_entry(entry) }
        }
      end

      def matched_entry(entry, applied)
        {
          index:            entry[:index],
          input:            entry[:input],
          product:          ProductSerializer.serialize(entry[:product]),
          match_source:     entry[:match_source],
          similarity:       round3(entry[:similarity]),
          name_similarity:  round3(entry[:name_similarity]),
          brand_similarity: round3(entry[:brand_similarity]),
          inventory_item:   applied ? InventoryItemSerializer.serialize(entry[:inventory_item]) : nil
        }
      end

      def created_entry(entry, applied)
        {
          index:          entry[:index],
          input:          entry[:input],
          product:        applied ? ProductSerializer.serialize(entry[:product]) : nil,
          inventory_item: applied ? InventoryItemSerializer.serialize(entry[:inventory_item]) : nil
        }
      end

      def unmatched_entry(entry)
        {
          index:       entry[:index],
          input:       entry[:input],
          reason:      entry[:reason],
          suggestions: entry[:suggestions].map { |product| suggestion(product) }
        }
      end

      # All three scores, not just the combined one: per the brand-ties-at-1.000
      # measurement, `similarity` alone cannot explain *why* three products tied.
      def suggestion(product)
        {
          product_id:       product.id,
          name:             product.name,
          similarity:       round3(product.match_similarity),
          name_similarity:  round3(product.name_similarity),
          brand_similarity: round3(product.brand_similarity)
        }
      end

      def round3(value)
        value&.to_f&.round(3)
      end
    end
  end
end
