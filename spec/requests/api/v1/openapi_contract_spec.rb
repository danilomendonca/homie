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

  it "GET /v1/products/search" do
    create(:product, name: "Tostata Tradicional", brand: "Visconti", unit_type: :unit)
    get "/v1/products/search", params: { q: "TORRADA VISCONTI" }
    assert_response_schema_confirm(200)
  end

  it "GET /v1/product_aliases" do
    create(:product_alias, product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
    get "/v1/product_aliases"
    assert_response_schema_confirm(200)
  end

  it "GET /v1/product_aliases/lookup" do
    create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba",
      product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
    get "/v1/product_aliases/lookup", params: { abbreviation: "refrig coca 2l", store_name: "Oba" }
    assert_response_schema_confirm(200)
  end

  it "DELETE /v1/inventory_items" do
    create(:inventory_item, product: create(:product, name: "Milk", unit_type: :volume))
    delete "/v1/inventory_items", params: { confirm: "true" }
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

  it "POST /v1/inventory/import" do
    create(:product, name: "Leite Integral", unit_type: :volume)
    create(:product, name: "Pão de Forma Integral", unit_type: :unit)
    # dry_run so the round-trip is side-effect-free; the response shape is the
    # same in both modes, with the ids nulled.
    post "/v1/inventory/import", params: {
      dry_run: true,
      items: [
        { name: "leite integral", quantity: 500 },
        { name: "pao de forma", quantity: 1 }
      ]
    }, as: :json
    assert_response_schema_confirm(200)
  end

  # The dry run above nulls every nested object, so it cannot validate them; this
  # exercises the populated product / inventory_item branches of the same schema.
  it "POST /v1/inventory/import (applied)" do
    create(:product, name: "Leite Integral", unit_type: :volume)
    post "/v1/inventory/import", params: {
      create_unknown: true,
      items: [
        { name: "leite integral", quantity: 500 },
        { name: "Farinha de Mandioca", quantity: 1, unit_type: "weight" }
      ]
    }, as: :json
    assert_response_schema_confirm(200)
  end

  it "GET /v1/inventory/sample" do
    product = create(:product, name: "Arroz", unit_type: :weight, low_stock_threshold: 1000)
    create(:inventory_item, product: product, quantity: 500)
    # A never-verified product alongside a verified one, so the round-trip covers
    # both the null and the populated stock_verified_at.
    create(:product, name: "Feijão", unit_type: :weight)
      .update_column(:stock_verified_at, 2.days.ago)
    get "/v1/inventory/sample"
    assert_response_schema_confirm(200)
  end

  it "POST /v1/inventory/verify" do
    product = create(:product, name: "Arroz", unit_type: :weight)
    create(:inventory_item, product: product, quantity: 500)
    post "/v1/inventory/verify", params: {
      items: [ { product_id: product.id, quantity: 750 } ]
    }, as: :json
    assert_response_schema_confirm(200)
  end

  it "POST /v1/inventory/consume" do
    product = create(:product, name: "Arroz", unit_type: :weight)
    create(:inventory_item, product: product, quantity: 500)
    post "/v1/inventory/consume", params: {
      items: [ { product_id: product.id, quantity: 200 } ]
    }, as: :json
    assert_response_schema_confirm(200)
  end

  it "POST /v1/inventory_items growing the default batch" do
    product = create(:product, name: "Arroz", unit_type: :weight)
    create(:inventory_item, product: product, quantity: 500)
    post "/v1/inventory_items", params: { product_id: product.id, quantity: 200 }, as: :json
    expect(response).to have_http_status(:ok)
    assert_response_schema_confirm(200)
  end

  it "GET /v1/openapi.json serves a valid OpenAPI 3 document" do
    get "/v1/openapi.json"
    expect(response).to have_http_status(:ok)
    doc = JSON.parse(response.body)
    expect(doc["openapi"]).to match(/\A3\./)
    expect(doc["paths"]).to include(
      "/v1/categories", "/v1/products", "/v1/products/search", "/v1/inventory_items",
      "/v1/inventory", "/v1/inventory/low_stock", "/v1/inventory/near_expiration",
      "/v1/inventory/import", "/v1/inventory/sample", "/v1/inventory/verify",
      "/v1/inventory/consume",
      "/v1/product_aliases", "/v1/product_aliases/lookup"
    )
  end
end
