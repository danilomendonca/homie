require "rails_helper"

RSpec.configure do |config|
  config.openapi_root = Rails.root.join("swagger").to_s

  config.openapi_specs = {
    "openapi.json" => {
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
              # nullable is load-bearing: every product serializes null here until
              # POST /v1/inventory/verify first counts it.
              stock_verified_at:   { type: :string, format: :"date-time", nullable: true },
              created_at:          { type: :string, format: :"date-time" },
              updated_at:          { type: :string, format: :"date-time" }
            },
            required: %w[id name brand notes category unit_type low_stock_threshold
                         stock_verified_at created_at updated_at]
          },
          product_alias: {
            type: :object,
            properties: {
              id:           { type: :string, format: :uuid },
              abbreviation: { type: :string },
              store_name:   { type: :string, nullable: true },
              product:      { "$ref" => "#/components/schemas/product" },
              created_at:   { type: :string, format: :"date-time" },
              updated_at:   { type: :string, format: :"date-time" }
            },
            required: %w[id abbreviation store_name product created_at updated_at]
          },
          product_search_result: {
            type: :object,
            properties: {
              product:          { "$ref" => "#/components/schemas/product" },
              similarity:       { type: :number },
              name_similarity:  { type: :number },
              brand_similarity: { type: :number }
            },
            required: %w[product similarity name_similarity brand_similarity]
          },
          product_search_response: {
            type: :object,
            properties: {
              results: {
                type: :array,
                items: { "$ref" => "#/components/schemas/product_search_result" }
              }
            },
            required: %w[results]
          },
          inventory_reset_response: {
            type: :object,
            properties: { deleted: { type: :integer } },
            required: %w[deleted]
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
          },
          product_bulk_failure_item: {
            type: :object,
            properties: {
              index:  { type: :integer },
              input:  { type: :object, additionalProperties: true },
              errors: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    field:   { type: :string },
                    message: { type: :string }
                  },
                  required: %w[message]
                }
              }
            },
            required: %w[index input errors]
          },
          inventory_item: {
            type: :object,
            properties: {
              id: { type: :string, format: :uuid },
              product: {
                type: :object,
                properties: {
                  id:                  { type: :string, format: :uuid },
                  name:                { type: :string },
                  unit_type:           { type: :string, enum: %w[unit weight volume] },
                  low_stock_threshold: { type: :number, nullable: true }
                },
                required: %w[id name unit_type low_stock_threshold]
              },
              quantity:        { type: :number },
              expiration_date: { type: :string, format: :date, nullable: true },
              created_at:      { type: :string, format: :"date-time" },
              updated_at:      { type: :string, format: :"date-time" }
            },
            required: %w[id product quantity expiration_date created_at updated_at]
          },
          inventory_item_bulk_request: {
            type: :object,
            properties: {
              inventory_items: {
                type: :array,
                maxItems: 500,
                items: {
                  type: :object,
                  properties: {
                    product_id:      { type: :string, format: :uuid },
                    quantity:        { type: :number },
                    expiration_date: { type: :string, format: :date, nullable: true }
                  },
                  required: %w[product_id quantity]
                }
              }
            },
            required: %w[inventory_items]
          },
          inventory_item_bulk_response: {
            type: :object,
            properties: {
              created: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_item" }
              },
              updated: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_item" }
              }
            },
            required: %w[created updated]
          },
          inventory_item_bulk_failure_item: {
            type: :object,
            properties: {
              index:  { type: :integer },
              input:  { type: :object, additionalProperties: true },
              errors: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    field:   { type: :string },
                    message: { type: :string }
                  },
                  required: %w[message]
                }
              }
            },
            required: %w[index input errors]
          },
          inventory_item_bulk_failure_response: {
            type: :object,
            properties: {
              failed: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_item_bulk_failure_item" }
              }
            },
            required: %w[failed]
          },
          product_bulk_failure_response: {
            type: :object,
            properties: {
              failed: {
                type: :array,
                items: { "$ref" => "#/components/schemas/product_bulk_failure_item" }
              }
            },
            required: %w[failed]
          },
          inventory_aggregate_batch: {
            type: :object,
            properties: {
              id:              { type: :string, format: :uuid },
              quantity:        { type: :number },
              expiration_date: { type: :string, format: :date, nullable: true }
            },
            required: %w[id quantity expiration_date]
          },
          inventory_aggregate_item: {
            type: :object,
            properties: {
              product_id:     { type: :string, format: :uuid },
              product_name:   { type: :string },
              unit_type:      { type: :string, enum: %w[unit weight volume] },
              total_quantity: { type: :number },
              batches: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_aggregate_batch" }
              }
            },
            required: %w[product_id product_name unit_type total_quantity batches]
          },
          inventory_low_stock_batch: {
            type: :object,
            properties: {
              id:              { type: :string, format: :uuid },
              quantity:        { type: :number },
              expiration_date: { type: :string, format: :date, nullable: true }
            },
            required: %w[id quantity expiration_date]
          },
          inventory_low_stock_item: {
            type: :object,
            properties: {
              product_id:          { type: :string, format: :uuid },
              product_name:        { type: :string },
              unit_type:           { type: :string, enum: %w[unit weight volume] },
              total_quantity:      { type: :number },
              low_stock_threshold: { type: :number },
              batches: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_low_stock_batch" }
              }
            },
            required: %w[product_id product_name unit_type total_quantity low_stock_threshold batches]
          },
          inventory_near_expiration_item: {
            type: :object,
            properties: {
              id:              { type: :string, format: :uuid },
              product_id:      { type: :string, format: :uuid },
              product_name:    { type: :string },
              unit_type:       { type: :string, enum: %w[unit weight volume] },
              quantity:        { type: :number },
              expiration_date: { type: :string, format: :date }
            },
            required: %w[id product_id product_name unit_type quantity expiration_date]
          },
          inventory_near_expiration_response: {
            type: :object,
            properties: {
              expired: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_near_expiration_item" }
              },
              near_expiration: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_near_expiration_item" }
              }
            },
            required: %w[expired near_expiration]
          },
          inventory_import_request: {
            type: :object,
            properties: {
              store_name:           { type: :string, nullable: true },
              dry_run:              { type: :boolean },
              create_unknown:       { type: :boolean },
              auto_match_threshold: { type: :number },
              items: {
                type: :array,
                maxItems: 500,
                items: {
                  type: :object,
                  properties: {
                    name:            { type: :string },
                    quantity:        { type: :number },
                    expiration_date: { type: :string, format: :date, nullable: true },
                    brand:           { type: :string, nullable: true },
                    unit_type:       { type: :string, enum: %w[unit weight volume] },
                    category_id:     { type: :string, format: :uuid, nullable: true }
                  },
                  required: %w[name quantity]
                }
              }
            },
            required: %w[items]
          },
          inventory_import_suggestion: {
            type: :object,
            properties: {
              product_id:       { type: :string, format: :uuid },
              name:             { type: :string },
              similarity:       { type: :number },
              name_similarity:  { type: :number },
              brand_similarity: { type: :number }
            },
            required: %w[product_id name similarity name_similarity brand_similarity]
          },
          inventory_import_matched_item: {
            type: :object,
            properties: {
              index:            { type: :integer },
              input:            { type: :object, additionalProperties: true },
              product:          { "$ref" => "#/components/schemas/product" },
              match_source:     { type: :string, enum: %w[exact alias similarity] },
              similarity:       { type: :number, nullable: true },
              name_similarity:  { type: :number, nullable: true },
              brand_similarity: { type: :number, nullable: true },
              inventory_item: {
                allOf: [ { "$ref" => "#/components/schemas/inventory_item" } ],
                nullable: true
              }
            },
            required: %w[
              index input product match_source similarity name_similarity
              brand_similarity inventory_item
            ]
          },
          inventory_import_created_item: {
            type: :object,
            properties: {
              index: { type: :integer },
              input: { type: :object, additionalProperties: true },
              product: {
                allOf: [ { "$ref" => "#/components/schemas/product" } ],
                nullable: true
              },
              inventory_item: {
                allOf: [ { "$ref" => "#/components/schemas/inventory_item" } ],
                nullable: true
              }
            },
            required: %w[index input product inventory_item]
          },
          inventory_import_unmatched_item: {
            type: :object,
            properties: {
              index:  { type: :integer },
              input:  { type: :object, additionalProperties: true },
              reason: { type: :string, enum: %w[below_threshold ambiguous_match missing_unit_type] },
              suggestions: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_import_suggestion" }
              }
            },
            required: %w[index input reason suggestions]
          },
          inventory_import_response: {
            type: :object,
            properties: {
              applied: { type: :boolean },
              matched: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_import_matched_item" }
              },
              created: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_import_created_item" }
              },
              unmatched: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_import_unmatched_item" }
              }
            },
            required: %w[applied matched created unmatched]
          },
          inventory_sample_item: {
            type: :object,
            properties: {
              product_id:          { type: :string, format: :uuid },
              product_name:        { type: :string },
              unit_type:           { type: :string, enum: %w[unit weight volume] },
              total_quantity:      { type: :number },
              low_stock_threshold: { type: :number, nullable: true },
              stock_verified_at:   { type: :string, format: :"date-time", nullable: true }
            },
            required: %w[product_id product_name unit_type total_quantity
                         low_stock_threshold stock_verified_at]
          },
          inventory_sample_response: {
            type: :object,
            properties: {
              items: {
                type: :array,
                items: { "$ref" => "#/components/schemas/inventory_sample_item" }
              }
            },
            required: %w[items]
          },
          inventory_verify_request: {
            type: :object,
            properties: {
              items: {
                type: :array,
                maxItems: 500,
                items: {
                  type: :object,
                  properties: {
                    product_id: { type: :string, format: :uuid },
                    quantity:   { type: :number }
                  },
                  required: %w[product_id quantity]
                }
              }
            },
            required: %w[items]
          },
          inventory_verify_response: {
            type: :object,
            properties: { verified: { type: :integer } },
            required: %w[verified]
          }
        }
      }
    }
  }

  config.openapi_format = :json
end
