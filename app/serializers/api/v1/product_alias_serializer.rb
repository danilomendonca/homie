module Api
  module V1
    module ProductAliasSerializer
      module_function

      def serialize(record)
        {
          id:           record.id,
          abbreviation: record.abbreviation,
          store_name:   record.store_name,
          product:      ProductSerializer.serialize(record.product),
          created_at:   record.created_at.utc.iso8601,
          updated_at:   record.updated_at.utc.iso8601
        }
      end
    end
  end
end
