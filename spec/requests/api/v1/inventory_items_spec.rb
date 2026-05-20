require "swagger_helper"

RSpec.describe "Api::V1::InventoryItems", type: :request do
  path "/v1/inventory_items" do
    get "Lists inventory items" do
      tags "InventoryItems"
      produces "application/json"
      parameter name: :product_id, in: :query, type: :string, required: false

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
          expect(body["product_id"]).to eq(product.id)
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
          expect(body["product_id"]).to eq(item.product_id)
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
end
