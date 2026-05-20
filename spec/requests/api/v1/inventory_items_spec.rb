require "swagger_helper"

RSpec.describe "Api::V1::InventoryItems", type: :request do
  path "/v1/inventory_items" do
    get "Lists inventory items" do
      tags "InventoryItems"
      produces "application/json"
      parameter name: :product_id, in: :query, type: :string, required: false
      parameter name: :low_stock, in: :query, type: :string, required: false

      response "200", "lists items ordered by expiration_date ASC NULLS LAST, created_at ASC" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }

        before do
          @later  = create(:inventory_item, expiration_date: Date.current + 5)
          @sooner = create(:inventory_item, expiration_date: Date.current + 1)
          @nodate = create(:inventory_item, expiration_date: nil)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |i| i["id"] }).to eq([ @sooner.id, @later.id, @nodate.id ])
        end
      end

      response "200", "orders by created_at ASC when expiration dates tie" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }

        before do
          @first  = create(:inventory_item, expiration_date: Date.current + 3)
          @second = create(:inventory_item, expiration_date: Date.current + 3)
          @first.update_columns(created_at: 2.seconds.ago)
          @second.update_columns(created_at: 1.second.ago)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |i| i["id"] }).to eq([ @first.id, @second.id ])
        end
      end

      response "200", "filters by product_id" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_a) { create(:product) }
        let(:product_b) { create(:product) }
        let(:product_id) { product_a.id }

        before do
          @match = create(:inventory_item, product: product_a)
          create(:inventory_item, product: product_b)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |i| i["id"] }).to eq([ @match.id ])
        end
      end

      response "200", "treats empty product_id as absent" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { "" }

        before do
          create(:inventory_item)
          create(:inventory_item)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(2)
        end
      end

      response "200", "embeds product { id, name, unit_type, low_stock_threshold }" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }

        before do
          @product = create(:product, low_stock_threshold: 3, unit_type: :unit)
          @item = create(:inventory_item, product: @product)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          row = body.find { |i| i["id"] == @item.id }
          expect(row["product"]).to eq(
            "id" => @product.id,
            "name" => @product.name,
            "unit_type" => "unit",
            "low_stock_threshold" => 3.0
          )
          expect(row).not_to have_key("product_id")
        end
      end

      response "200", "?low_stock=true excludes products at exactly threshold (strict <)" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }
        let(:low_stock) { "true" }

        before do
          at_threshold = create(:product, low_stock_threshold: 5)
          create(:inventory_item, product: at_threshold, quantity: 5)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body).to be_empty
        end
      end

      response "200", "?low_stock=true includes products below threshold" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }
        let(:low_stock) { "true" }

        before do
          below = create(:product, low_stock_threshold: 5)
          @batch = create(:inventory_item, product: below, quantity: 4)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |i| i["id"] }).to eq([ @batch.id ])
        end
      end

      response "200", "?low_stock=true excludes products with nil threshold even when stock is zero" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }
        let(:low_stock) { "true" }

        before do
          no_threshold = create(:product, low_stock_threshold: nil)
          create(:inventory_item, product: no_threshold, quantity: 0)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body).to be_empty
        end
      end

      response "200", "?low_stock=true returns all batches for a below-threshold product" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }
        let(:low_stock) { "true" }

        before do
          product = create(:product, low_stock_threshold: 10)
          @b1 = create(:inventory_item, product: product, quantity: 2, expiration_date: Date.current + 1)
          @b2 = create(:inventory_item, product: product, quantity: 3, expiration_date: Date.current + 5)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |i| i["id"] }).to match_array([ @b1.id, @b2.id ])
        end
      end

      response "200", "?low_stock=true with multiple products shows only below-threshold ones" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }
        let(:low_stock) { "true" }

        before do
          low = create(:product, low_stock_threshold: 10)
          @low_batch = create(:inventory_item, product: low, quantity: 1)
          ok = create(:product, low_stock_threshold: 2)
          create(:inventory_item, product: ok, quantity: 5)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |i| i["id"] }).to eq([ @low_batch.id ])
        end
      end

      response "200", "?low_stock=false is treated as absent (no filter applied)" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_item" }
        let(:product_id) { nil }
        let(:low_stock) { "false" }

        before do
          create(:inventory_item)
          create(:inventory_item)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(2)
        end
      end
    end

    post "Creates an inventory item" do
      tags "InventoryItems"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          product_id:      { type: :string, format: :uuid },
          quantity:        { type: :number },
          expiration_date: { type: :string, format: :date, nullable: true }
        },
        required: %w[product_id quantity]
      }

      response "201", "creates with full payload" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:product) { create(:product) }
        let(:payload) do
          { product_id: product.id, quantity: 3, expiration_date: (Date.current + 7).iso8601 }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["product"]["id"]).to eq(product.id)
          expect(body["product"]["name"]).to eq(product.name)
          expect(body["product"]["unit_type"]).to eq(product.unit_type)
          expect(body["product"]["low_stock_threshold"]).to eq(product.low_stock_threshold)
          expect(body).not_to have_key("product_id")
          expect(body["quantity"]).to eq(3.0)
          expect(body["expiration_date"]).to eq((Date.current + 7).iso8601)
          expect(body["id"]).to be_present
        end
      end

      response "201", "creates with minimal payload (expiration_date omitted)" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:product) { create(:product) }
        let(:payload) { { product_id: product.id, quantity: 2 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expiration_date"]).to be_nil
        end
      end

      response "201", "accepts today as expiration_date (boundary)" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:product) { create(:product) }
        let(:payload) do
          { product_id: product.id, quantity: 1, expiration_date: Date.current.iso8601 }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expiration_date"]).to eq(Date.current.iso8601)
        end
      end

      response "422", "rejects past expiration_date" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) do
          { product_id: product.id, quantity: 1, expiration_date: (Date.current - 1).iso8601 }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("expiration_date")
        end
      end

      response "422", "rejects missing product_id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { quantity: 1 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields & %w[product product_id]).not_to be_empty
        end
      end

      response "422", "rejects nonexistent product_id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { product_id: SecureRandom.uuid, quantity: 1 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("product_id")
        end
      end

      response "422", "rejects missing quantity" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) { { product_id: product.id } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("quantity")
        end
      end

      response "422", "rejects negative quantity" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) { { product_id: product.id, quantity: -1 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("quantity")
        end
      end

      response "422", "rejects fractional quantity for unit_type=unit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product, unit_type: :unit) }
        let(:payload) { { product_id: product.id, quantity: 1.5 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("quantity")
        end
      end

      response "201", "accepts integer quantity for unit_type=unit" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:product) { create(:product, unit_type: :unit) }
        let(:payload) { { product_id: product.id, quantity: 2 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["quantity"]).to eq(2.0)
        end
      end

      response "201", "accepts mathematically-whole decimal for unit_type=unit" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:product) { create(:product, unit_type: :unit) }
        let(:payload) { { product_id: product.id, quantity: 2.000 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["quantity"]).to eq(2.0)
        end
      end

      response "201", "accepts fractional quantity for unit_type=weight" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:product) { create(:product, unit_type: :weight) }
        let(:payload) { { product_id: product.id, quantity: 1.5 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["quantity"]).to eq(1.5)
        end
      end

      response "201", "coerces JSON string quantity via numericality" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:product) { create(:product) }
        let(:payload) { { product_id: product.id, quantity: "2" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["quantity"]).to eq(2.0)
        end
      end
    end
  end

  path "/v1/inventory_items/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid

    get "Shows an inventory item" do
      tags "InventoryItems"
      produces "application/json"

      response "200", "returns the item" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:item) { create(:inventory_item) }
        let(:id) { item.id }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["id"]).to eq(item.id)
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

    patch "Updates an inventory item" do
      tags "InventoryItems"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          product_id:      { type: :string, format: :uuid, nullable: true },
          quantity:        { type: :number, nullable: true },
          expiration_date: { type: :string, format: :date, nullable: true }
        }
      }

      response "200", "changes quantity only" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:item) { create(:inventory_item, quantity: 1) }
        let(:id) { item.id }
        let(:payload) { { quantity: 5 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["quantity"]).to eq(5.0)
          expect(item.reload.quantity).to eq(5)
        end
      end

      response "200", "clears expiration_date with null" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:item) { create(:inventory_item, expiration_date: Date.current + 5) }
        let(:id) { item.id }
        let(:payload) { { expiration_date: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expiration_date"]).to be_nil
          expect(item.reload.expiration_date).to be_nil
        end
      end

      response "200", "allows past expiration_date on PATCH (on: :create does not fire)" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:item) { create(:inventory_item, expiration_date: Date.current + 5) }
        let(:id) { item.id }
        let(:payload) { { expiration_date: (Date.current - 5).iso8601 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expiration_date"]).to eq((Date.current - 5).iso8601)
        end
      end

      response "200", "sending same product_id is a no-op" do
        schema "$ref" => "#/components/schemas/inventory_item"
        let(:item) { create(:inventory_item) }
        let(:id) { item.id }
        let(:payload) { { product_id: item.product_id } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["product"]["id"]).to eq(item.product_id)
        end
      end

      response "422", "rejects changing product_id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:item) { create(:inventory_item) }
        let(:other_product) { create(:product) }
        let(:id) { item.id }
        let(:payload) { { product_id: other_product.id } }

        run_test! do |response|
          body = JSON.parse(response.body)
          err = body["errors"].find { |e| e["field"] == "product_id" }
          expect(err).not_to be_nil
          expect(err["message"]).to match(/immutable/)
          expect(item.reload.product_id).not_to eq(other_product.id)
        end
      end

      response "422", "rejects null product_id with 'is immutable' (not 'can't be blank')" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:item) { create(:inventory_item) }
        let(:id) { item.id }
        let(:payload) { { product_id: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          err = body["errors"].find { |e| e["field"] == "product_id" }
          expect(err).not_to be_nil
          expect(err["message"]).to match(/immutable/)
        end
      end

      response "422", "rejects null quantity" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:item) { create(:inventory_item, quantity: 3) }
        let(:id) { item.id }
        let(:payload) { { quantity: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("quantity")
        end
      end

      response "422", "rejects fractional quantity on unit_type=unit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product, unit_type: :unit) }
        let(:item) { create(:inventory_item, product: product, quantity: 2) }
        let(:id) { item.id }
        let(:payload) { { quantity: 1.5 } }

        run_test! do |response|
          body = JSON.parse(response.body)
          fields = body["errors"].map { |e| e["field"] }
          expect(fields).to include("quantity")
        end
      end
    end

    delete "Deletes an inventory item" do
      tags "InventoryItems"

      response "204", "deletes a zero-quantity item" do
        let(:item) { create(:inventory_item, quantity: 0) }
        let(:id) { item.id }

        run_test! do
          expect(InventoryItem.exists?(id)).to be(false)
        end
      end

      response "204", "deletes an active-stock item (no 409 path here)" do
        let(:item) { create(:inventory_item, quantity: 5) }
        let(:id) { item.id }

        run_test! do
          expect(InventoryItem.exists?(id)).to be(false)
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

  path "/v1/inventory_items/bulk" do
    post "Bulk creates or merges inventory items by (product_id, expiration_date)" do
      tags "InventoryItems"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body,
        schema: { "$ref" => "#/components/schemas/inventory_item_bulk_request" }

      response "201", "creates two distinct batches when no existing matches" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:p1) { create(:product, unit_type: :unit) }
        let(:p2) { create(:product, unit_type: :weight) }
        let(:payload) do
          {
            inventory_items: [
              { product_id: p1.id, quantity: 2, expiration_date: (Date.current + 3).iso8601 },
              { product_id: p2.id, quantity: 1.5 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["updated"]).to eq([])
          expect(body["created"].length).to eq(2)
          expect(body["created"].map { |i| i["product"]["id"] }).to match_array([ p1.id, p2.id ])
          expect(InventoryItem.count).to eq(2)
        end
      end

      response "201", "merges into existing batch with same (product_id, expiration_date)" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:exp) { Date.current + 4 }

        before do
          @existing = create(:inventory_item, product: product, quantity: 2, expiration_date: exp)
        end

        let(:payload) do
          { inventory_items: [ { product_id: product.id, quantity: 3, expiration_date: exp.iso8601 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"]).to eq([])
          expect(body["updated"].length).to eq(1)
          expect(body["updated"].first["id"]).to eq(@existing.id)
          expect(body["updated"].first["quantity"]).to eq(5.0)
          expect(@existing.reload.quantity).to eq(5)
          expect(InventoryItem.count).to eq(1)
        end
      end

      response "201", "mixes a create and a merge in one request" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:matched_exp) { Date.current + 4 }
        let(:new_exp) { Date.current + 9 }

        before do
          @existing = create(:inventory_item, product: product, quantity: 1, expiration_date: matched_exp)
        end

        let(:payload) do
          {
            inventory_items: [
              { product_id: product.id, quantity: 2, expiration_date: matched_exp.iso8601 },
              { product_id: product.id, quantity: 4, expiration_date: new_exp.iso8601 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["updated"].length).to eq(1)
          expect(body["updated"].first["id"]).to eq(@existing.id)
          expect(body["updated"].first["quantity"]).to eq(3.0)
          expect(body["created"].length).to eq(1)
          expect(body["created"].first["quantity"]).to eq(4.0)
          expect(InventoryItem.count).to eq(2)
        end
      end

      response "201", "sums two entries that share the same key (single resulting batch)" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:exp) { Date.current + 6 }
        let(:payload) do
          {
            inventory_items: [
              { product_id: product.id, quantity: 2, expiration_date: exp.iso8601 },
              { product_id: product.id, quantity: 3, expiration_date: exp.iso8601 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"].length).to eq(1)
          expect(body["created"].first["quantity"]).to eq(5.0)
          expect(body["updated"]).to eq([])
          expect(InventoryItem.count).to eq(1)
        end
      end

      response "201", "accepts an empty inventory_items array" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:payload) { { inventory_items: [] } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body).to eq({ "created" => [], "updated" => [] })
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "201", "merges when both existing and bulk entry have nil expiration_date" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:product) { create(:product, unit_type: :unit) }

        before do
          @existing = create(:inventory_item, product: product, quantity: 4, expiration_date: nil)
        end

        let(:payload) do
          { inventory_items: [ { product_id: product.id, quantity: 2, expiration_date: nil } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"]).to eq([])
          expect(body["updated"].length).to eq(1)
          expect(body["updated"].first["id"]).to eq(@existing.id)
          expect(body["updated"].first["quantity"]).to eq(6.0)
        end
      end

      response "201", "two same-key fractional entries on unit_type=unit sum to a whole number" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:exp) { Date.current + 2 }
        let(:payload) do
          {
            inventory_items: [
              { product_id: product.id, quantity: 1.5, expiration_date: exp.iso8601 },
              { product_id: product.id, quantity: 1.5, expiration_date: exp.iso8601 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"].length).to eq(1)
          expect(body["created"].first["quantity"]).to eq(3.0)
        end
      end

      response "201", "allows past expiration_date when merging into a matching existing batch" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:past) { Date.current - 5 }

        before do
          @existing = create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 1)
          @existing.update_columns(expiration_date: past)
        end

        let(:payload) do
          { inventory_items: [ { product_id: product.id, quantity: 2, expiration_date: past.iso8601 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["updated"].length).to eq(1)
          expect(body["updated"].first["id"]).to eq(@existing.id)
          expect(body["updated"].first["quantity"]).to eq(3.0)
        end
      end

      response "422", "rejects fractional quantity on unit_type=unit when group sum is fractional" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:payload) do
          { inventory_items: [ { product_id: product.id, quantity: 1.5 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          failure = body["failed"].first
          expect(failure["index"]).to eq(0)
          expect(failure["errors"].map { |e| e["field"] }).to include("quantity")
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "422", "rejects past expiration_date when creating a new batch" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:payload) do
          {
            inventory_items: [
              { product_id: product.id, quantity: 1, expiration_date: (Date.current - 2).iso8601 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          expect(body["failed"].first["errors"].map { |e| e["field"] }).to include("expiration_date")
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "422", "rolls back the whole bulk when any row is invalid" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"
        let(:product) { create(:product, unit_type: :unit) }
        let(:past) { Date.current - 3 }

        before do
          @existing = create(:inventory_item, product: product, quantity: 2, expiration_date: Date.current + 1)
          @existing.update_columns(expiration_date: past)
        end

        let(:payload) do
          {
            inventory_items: [
              { product_id: product.id, quantity: 5, expiration_date: past.iso8601 },
              { product_id: product.id, quantity: 1, expiration_date: (Date.current - 10).iso8601 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          expect(body["failed"].first["index"]).to eq(1)
          expect(@existing.reload.quantity).to eq(2)
        end
      end

      response "422", "fails when product_id does not exist" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"
        let(:payload) do
          { inventory_items: [ { product_id: SecureRandom.uuid, quantity: 1 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          expect(body["failed"].first["errors"].map { |e| e["field"] }).to include("product_id")
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "422", "fails when product_id is missing" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"
        let(:payload) do
          { inventory_items: [ { quantity: 1 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          fields = body["failed"].first["errors"].map { |e| e["field"] }
          expect(fields & %w[product product_id]).not_to be_empty
        end
      end

      response "422", "shape-fails on negative quantity" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"
        let(:product) { create(:product) }
        let(:payload) do
          { inventory_items: [ { product_id: product.id, quantity: -1 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          expect(body["failed"].first["index"]).to eq(0)
          expect(body["failed"].first["errors"].map { |e| e["field"] }).to include("quantity")
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "422", "shape-fails on missing quantity" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"
        let(:product) { create(:product) }
        let(:payload) do
          { inventory_items: [ { product_id: product.id } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          expect(body["failed"].first["errors"].map { |e| e["field"] }).to include("quantity")
        end
      end

      response "400", "rejects body without inventory_items key" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { {} }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end

      response "400", "rejects when inventory_items is not an array" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { inventory_items: "not an array" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end

      response "400", "rejects inventory_items array exceeding the limit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) do
          { inventory_items: Array.new(501) { { product_id: product.id, quantity: 1 } } }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to match(/maximum/)
          expect(InventoryItem.count).to eq(0)
        end
      end
    end
  end
end
