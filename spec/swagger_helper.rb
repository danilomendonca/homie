require "rails_helper"

RSpec.configure do |config|
  config.openapi_root = Rails.root.join("swagger").to_s

  config.openapi_specs = {
    "v1/swagger.json" => {
      openapi: "3.0.1",
      info: {
        title: "Homie API V1",
        version: "v1"
      },
      paths: {},
      components: {
        schemas: {
          error_object: {
            type: :object,
            properties: {
              field: { type: :string },
              message: { type: :string }
            },
            required: %w[message]
          },
          error_envelope: {
            type: :object,
            properties: {
              errors: {
                type: :array,
                items: { "$ref" => "#/components/schemas/error_object" }
              }
            },
            required: %w[errors]
          },
          category: {
            type: :object,
            properties: {
              id:         { type: :string, format: :uuid },
              name:       { type: :string },
              created_at: { type: :string, format: :"date-time" },
              updated_at: { type: :string, format: :"date-time" }
            },
            required: %w[id name created_at updated_at]
          }
        }
      }
    }
  }

  config.openapi_format = :json
end
