require "swagger_helper"

RSpec.describe "Api::V1::Products", type: :request do
  path "/v1/products" do
    get "Lists products" do
      tags "Products"
      produces "application/json"
      parameter name: :category_id, in: :query, type: :string, required: false
      parameter name: :search, in: :query, type: :string, required: false

      response "200", "lists products ordered by name ASC" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product" }
        let(:category_id) { nil }
        let(:search) { nil }

        before do
          create(:product, name: "Bread")
          create(:product, name: "Apple")
          create(:product, name: "Cheese")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |p| p["name"] }).to eq(%w[Apple Bread Cheese])
        end
      end

      response "200", "filters by category_id" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product" }
        let(:dairy) { create(:category, name: "Dairy") }
        let(:produce) { create(:category, name: "Produce") }
        let(:category_id) { dairy.id }
        let(:search) { nil }

        before do
          create(:product, name: "Milk", category: dairy)
          create(:product, name: "Cheese", category: dairy)
          create(:product, name: "Apple", category: produce)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |p| p["name"] }).to eq(%w[Cheese Milk])
        end
      end

      response "200", "filters by search (case-insensitive substring) and orders by name" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product" }
        let(:category_id) { nil }
        let(:search) { "ilk" }

        before do
          create(:product, name: "Whole Milk")
          create(:product, name: "Almond Milk")
          create(:product, name: "Bread")
          create(:product, name: "Milk")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |p| p["name"] }).to eq([ "Almond Milk", "Milk", "Whole Milk" ])
        end
      end

      response "200", "treats empty category_id as absent" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product" }
        let(:category_id) { "" }
        let(:search) { nil }

        before do
          create(:product, name: "A")
          create(:product, name: "B")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |p| p["name"] }).to eq(%w[A B])
        end
      end

      response "200", "combines category_id and search filters" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product" }
        let(:dairy) { create(:category, name: "Dairy") }
        let(:produce) { create(:category, name: "Produce") }
        let(:category_id) { dairy.id }
        let(:search) { "milk" }

        before do
          create(:product, name: "Milk", category: dairy)
          create(:product, name: "Cheese", category: dairy)
          create(:product, name: "Almond Milk", category: produce)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |p| p["name"] }).to eq(%w[Milk])
        end
      end

      response "200", "search matches brand as well as name" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product" }
        let(:category_id) { nil }
        let(:search) { "nesc" }

        before do
          create(:product, name: "Coffee", brand: "Nescafé")
          create(:product, name: "Tea")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |p| p["name"] }).to eq(%w[Coffee])
          expect(body.first["brand"]).to eq("Nescafé")
        end
      end
    end

    post "Creates a product" do
      tags "Products"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          name:                { type: :string },
          category_id:         { type: :string, format: :uuid, nullable: true },
          unit_type:           { type: :string, enum: %w[unit weight volume] },
          low_stock_threshold: { type: :number, nullable: true }
        },
        required: %w[name unit_type]
      }

      response "201", "creates a product with full payload" do
        schema "$ref" => "#/components/schemas/product"
        let(:category) { create(:category, name: "Dairy") }
        let(:payload) do
          {
            name: "Milk",
            category_id: category.id,
            unit_type: "volume",
            low_stock_threshold: 1.5
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["name"]).to eq("Milk")
          expect(body["category"]).to eq({ "id" => category.id, "name" => "Dairy" })
          expect(body["unit_type"]).to eq("volume")
          expect(body["low_stock_threshold"]).to eq(1.5)
          expect(body["id"]).to be_present
        end
      end

      response "201", "creates a product with minimal payload" do
        schema "$ref" => "#/components/schemas/product"
        let(:payload) { { name: "Apple", unit_type: "unit" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["name"]).to eq("Apple")
          expect(body["category"]).to be_nil
          expect(body["brand"]).to be_nil
          expect(body["notes"]).to be_nil
          expect(body["low_stock_threshold"]).to be_nil
        end
      end

      response "201", "accepts category_id: null" do
        schema "$ref" => "#/components/schemas/product"
        let(:payload) { { name: "Apple", unit_type: "unit", category_id: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["category"]).to be_nil
        end
      end

      response "422", "rejects a duplicate name (case-insensitive via citext)" do
        schema "$ref" => "#/components/schemas/error_envelope"
        before { create(:product, name: "Milk") }
        let(:payload) { { name: "milk", unit_type: "volume" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["field"]).to eq("name")
        end
      end

      response "422", "rejects an empty body (missing name)" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { {} }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("name")
        end
      end

      response "422", "rejects missing unit_type" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { name: "Apple" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("unit_type")
        end
      end

      response "422", "rejects invalid unit_type" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { name: "Apple", unit_type: "foo" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("unit_type")
        end
      end

      response "422", "rejects nonexistent category_id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          { name: "Apple", unit_type: "unit", category_id: SecureRandom.uuid }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("category_id")
        end
      end

      response "422", "rejects fractional low_stock_threshold for unit_type=unit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          { name: "Apple", unit_type: "unit", low_stock_threshold: 1.5 }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("low_stock_threshold")
        end
      end

      response "201", "accepts fractional low_stock_threshold for unit_type=weight" do
        schema "$ref" => "#/components/schemas/product"
        let(:payload) do
          { name: "Cheese", unit_type: "weight", low_stock_threshold: 1.5 }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["low_stock_threshold"]).to eq(1.5)
        end
      end

      response "422", "rejects negative low_stock_threshold" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          { name: "Cheese", unit_type: "weight", low_stock_threshold: -1 }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("low_stock_threshold")
        end
      end
    end
  end

  path "/v1/products/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid

    get "Shows a product" do
      tags "Products"
      produces "application/json"

      response "200", "returns the product" do
        schema "$ref" => "#/components/schemas/product"
        let(:product) { create(:product, name: "Milk", unit_type: :volume) }
        let(:id) { product.id }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["id"]).to eq(product.id)
          expect(body["name"]).to eq("Milk")
          expect(body["unit_type"]).to eq("volume")
        end
      end

      response "404", "returns 404 when not found" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end
    end

    patch "Updates a product" do
      tags "Products"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          name:                { type: :string, nullable: true },
          category_id:         { type: :string, format: :uuid, nullable: true },
          unit_type:           { type: :string, enum: %w[unit weight volume], nullable: true },
          low_stock_threshold: { type: :number, nullable: true }
        }
      }

      response "200", "renames the product" do
        schema "$ref" => "#/components/schemas/product"
        let(:product) { create(:product, name: "Old") }
        let(:id) { product.id }
        let(:payload) { { name: "New" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["name"]).to eq("New")
          expect(product.reload.name).to eq("New")
        end
      end

      response "200", "clears category_id with null" do
        schema "$ref" => "#/components/schemas/product"
        let(:category) { create(:category) }
        let(:product) { create(:product, category: category) }
        let(:id) { product.id }
        let(:payload) { { category_id: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["category"]).to be_nil
          expect(product.reload.category_id).to be_nil
        end
      end

      response "200", "clears low_stock_threshold with null" do
        schema "$ref" => "#/components/schemas/product"
        let(:product) { create(:product, unit_type: :unit, low_stock_threshold: 5) }
        let(:id) { product.id }
        let(:payload) { { low_stock_threshold: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["low_stock_threshold"]).to be_nil
          expect(product.reload.low_stock_threshold).to be_nil
        end
      end

      response "422", "rejects null name" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product, name: "Old") }
        let(:id) { product.id }
        let(:payload) { { name: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("name")
          expect(product.reload.name).to eq("Old")
        end
      end

      response "422", "rejects null unit_type" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product, unit_type: :unit) }
        let(:id) { product.id }
        let(:payload) { { unit_type: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("unit_type")
        end
      end

      response "200", "changes unit_type when no inventory items exist" do
        schema "$ref" => "#/components/schemas/product"
        let(:product) { create(:product, unit_type: :unit) }
        let(:id) { product.id }
        let(:payload) { { unit_type: "weight" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["unit_type"]).to eq("weight")
        end
      end

      response "200", "no-op unit_type assignment with batches present is not a conflict" do
        schema "$ref" => "#/components/schemas/product"
        let(:product) { create(:product, unit_type: :unit) }
        let(:id) { product.id }
        let(:payload) { { unit_type: "unit" } }

        before { create(:inventory_item, product: product, quantity: 3) }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["unit_type"]).to eq("unit")
        end
      end

      response "409", "rejects unit_type change when inventory items exist" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product, unit_type: :unit) }
        let(:id) { product.id }
        let(:payload) { { unit_type: "weight" } }

        before { create(:inventory_item, product: product, quantity: 1) }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to match(/unit_type/)
          expect(product.reload.unit_type).to eq("unit")
        end
      end

      response "422", "invalid unit_type with batches returns 422 not 409" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product, unit_type: :unit) }
        let(:id) { product.id }
        let(:payload) { { unit_type: "foo" } }

        before { create(:inventory_item, product: product, quantity: 1) }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("unit_type")
        end
      end

      response "422", "rejects fractional low_stock_threshold on unit_type=unit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product, unit_type: :unit) }
        let(:id) { product.id }
        let(:payload) { { low_stock_threshold: 1.5 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("low_stock_threshold")
        end
      end

      response "200", "accepts unit_type and fractional threshold change together" do
        schema "$ref" => "#/components/schemas/product"
        let(:product) { create(:product, unit_type: :unit) }
        let(:id) { product.id }
        let(:payload) { { unit_type: "weight", low_stock_threshold: 1.5 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["unit_type"]).to eq("weight")
          expect(body["low_stock_threshold"]).to eq(1.5)
        end
      end
    end

    delete "Deletes a product" do
      tags "Products"

      response "204", "deletes a product with no inventory items" do
        let(:product) { create(:product) }
        let(:id) { product.id }

        run_test! do
          expect(Product.exists?(id)).to be(false)
        end
      end

      response "204", "deletes a product with zero-quantity batches (cascade)" do
        let(:product) { create(:product) }
        let(:id) { product.id }

        before do
          create(:inventory_item, product: product, quantity: 0)
          create(:inventory_item, product: product, quantity: 0)
        end

        run_test! do
          expect(Product.exists?(id)).to be(false)
          expect(InventoryItem.where(product_id: id).count).to eq(0)
        end
      end

      response "409", "rejects delete when active stock exists" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:id) { product.id }

        before do
          create(:inventory_item, product: product, quantity: 2)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
          expect(Product.exists?(id)).to be(true)
          expect(InventoryItem.where(product_id: id).count).to eq(1)
        end
      end

      response "404", "returns 404 for unknown id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end
    end
  end

  path "/v1/products/bulk" do
    post "Bulk-creates products" do
      tags "Products"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body,
        schema: { "$ref" => "#/components/schemas/product_bulk_request" }

      response "201", "creates multiple products" do
        schema "$ref" => "#/components/schemas/product_bulk_response"
        let(:category) { create(:category, name: "Beverages") }
        let(:payload) do
          {
            products: [
              { name: "Bulk1", unit_type: "unit", category_id: category.id },
              { name: "Bulk2", unit_type: "weight", brand: "Acme", notes: "keep cold" }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"].length).to eq(2)
          first, second = body["created"]
          expect(first["name"]).to eq("Bulk1")
          expect(first["category"]).to eq({ "id" => category.id, "name" => "Beverages" })
          expect(second["name"]).to eq("Bulk2")
          expect(second["category"]).to be_nil
          expect(second["brand"]).to eq("Acme")
          expect(second["notes"]).to eq("keep cold")
          expect(Product.count).to eq(2)
        end
      end

      response "201", "accepts an empty products array" do
        schema "$ref" => "#/components/schemas/product_bulk_response"
        let(:payload) { { products: [] } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body).to eq({ "created" => [] })
          expect(Product.count).to eq(0)
        end
      end

      response "422", "rolls back when one item is invalid" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          {
            products: [
              { name: "Good", unit_type: "unit" },
              { unit_type: "unit" }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          name_errors = body["errors"].select { |e| e["field"] == "name" }
          expect(name_errors).not_to be_empty
          expect(name_errors.first["index"]).to eq(1)
          expect(Product.count).to eq(0)
        end
      end

      response "422", "reports errors for every invalid item, not just the first" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          {
            products: [
              { name: "OK", unit_type: "unit" },
              { unit_type: "unit" },
              { name: "Also OK", unit_type: "foo" }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          indexes = body["errors"].map { |e| e["index"] }.uniq.sort
          expect(indexes).to eq([ 1, 2 ])
          expect(Product.count).to eq(0)
        end
      end

      response "422", "detects in-batch duplicate names (case-insensitive)" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          {
            products: [
              { name: "Coffee", unit_type: "unit" },
              { name: "coffee", unit_type: "unit" }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          dup = body["errors"].find { |e| e["field"] == "name" && e["message"].include?("duplicated") }
          expect(dup).not_to be_nil
          expect(dup["index"]).to eq(1)
          expect(Product.count).to eq(0)
        end
      end

      response "422", "rejects nonexistent category_id with the right index" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          {
            products: [
              { name: "OK", unit_type: "unit" },
              { name: "Bad", unit_type: "unit", category_id: SecureRandom.uuid }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          err = body["errors"].find { |e| e["field"] == "category_id" }
          expect(err).not_to be_nil
          expect(err["index"]).to eq(1)
          expect(Product.count).to eq(0)
        end
      end

      response "400", "rejects body without products key" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { {} }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end

      response "400", "rejects products array exceeding the limit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          { products: Array.new(501) { |i| { name: "P#{i}", unit_type: "unit" } } }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to match(/maximum/)
          expect(Product.count).to eq(0)
        end
      end

      response "400", "rejects when products is not an array" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { products: "not an array" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end
    end
  end
end
