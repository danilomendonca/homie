require "rails_helper"
require "committee/rails/test/methods"

RSpec.describe "OpenAPI contract round-trip", type: :request do
  include Committee::Rails::Test::Methods

  let(:committee_options) do
    {
      schema_path: Rails.root.join("swagger/openapi.json").to_s,
      query_hash_check: true,
      parse_response_by_content_type: true,
      prefix: ""
    }
  end

  it "GET /v1/categories" do
    create(:category, name: "Dairy")
    get "/v1/categories"
    assert_response_schema_confirm(200)
  end

  it "GET /v1/products" do
    create(:product, name: "Milk", unit_type: :volume)
    get "/v1/products"
    assert_response_schema_confirm(200)
  end

  it "GET /v1/inventory_items" do
    create(:inventory_item, product: create(:product, name: "Milk", unit_type: :volume))
    get "/v1/inventory_items"
    assert_response_schema_confirm(200)
  end

  it "GET /v1/inventory" do
    product = create(:product, name: "Milk", unit_type: :volume)
    create(:inventory_item, product: product, quantity: 1000)
    get "/v1/inventory"
    assert_response_schema_confirm(200)
  end

  it "GET /v1/inventory/low_stock" do
    product = create(:product, name: "Milk", unit_type: :volume, low_stock_threshold: 1000)
    create(:inventory_item, product: product, quantity: 500)
    get "/v1/inventory/low_stock"
    assert_response_schema_confirm(200)
  end

  it "GET /v1/inventory/near_expiration" do
    product = create(:product, name: "Yogurt", unit_type: :volume)
    create(:inventory_item, product: product, quantity: 200, expiration_date: Date.current + 1)
    get "/v1/inventory/near_expiration"
    assert_response_schema_confirm(200)
  end

  it "GET /v1/openapi.json serves a valid OpenAPI 3 document" do
    get "/v1/openapi.json"
    expect(response).to have_http_status(:ok)
    doc = JSON.parse(response.body)
    expect(doc["openapi"]).to match(/\A3\./)
    expect(doc["paths"]).to include(
      "/v1/categories", "/v1/products", "/v1/inventory_items",
      "/v1/inventory", "/v1/inventory/low_stock", "/v1/inventory/near_expiration"
    )
  end
end
