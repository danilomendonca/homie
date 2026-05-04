module Api
  module V1
    module CategorySerializer
      module_function

      def serialize(category)
        {
          id: category.id,
          name: category.name,
          created_at: category.created_at.utc.iso8601,
          updated_at: category.updated_at.utc.iso8601
        }
      end
    end
  end
end
