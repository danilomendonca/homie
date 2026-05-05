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
              index:   { type: :integer },
              field:   { type: :string },
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
          },
          product: {
            type: :object,
            properties: {
              id:    { type: :string, format: :uuid },
              name:  { type: :string },
              brand: { type: :string, nullable: true },
              notes: { type: :string, nullable: true },
              category: {
                type: :object,
                nullable: true,
                properties: {
                  id:   { type: :string, format: :uuid },
                  name: { type: :string }
                },
                required: %w[id name]
              },
              unit_type:           { type: :string, enum: %w[unit weight volume] },
              low_stock_threshold: { type: :number, nullable: true },
              created_at:          { type: :string, format: :"date-time" },
              updated_at:          { type: :string, format: :"date-time" }
            },
            required: %w[id name brand notes category unit_type low_stock_threshold created_at updated_at]
          },
          product_bulk_request: {
            type: :object,
            properties: {
              products: {
                type: :array,
                maxItems: 500,
                items: {
                  type: :object,
                  properties: {
                    name:                { type: :string },
                    brand:               { type: :string, nullable: true },
                    notes:               { type: :string, nullable: true },
                    category_id:         { type: :string, format: :uuid, nullable: true },
                    unit_type:           { type: :string, enum: %w[unit weight volume] },
                    low_stock_threshold: { type: :number, nullable: true }
                  },
                  required: %w[name unit_type]
                }
              }
            },
            required: %w[products]
          },
          product_bulk_response: {
            type: :object,
            properties: {
              created: {
                type: :array,
                items: { "$ref" => "#/components/schemas/product" }
              }
            },
            required: %w[created]
          }
        }
      }
    }
  }

  config.openapi_format = :json
end
