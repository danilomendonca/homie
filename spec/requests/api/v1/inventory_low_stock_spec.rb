require "swagger_helper"

RSpec.describe "Api::V1::InventoryLowStock", type: :request do
  path "/v1/inventory/low_stock" do
    get "Lists products grouped under their low-stock threshold" do
      tags "Inventory"
      produces "application/json"

      response "200", "excludes a product whose total is exactly at threshold (strict <)" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          product = create(:product, low_stock_threshold: 5)
          create(:inventory_item, product: product, quantity: 5)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body).to eq([])
        end
      end

      response "200", "includes a product whose summed batches fall below threshold" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          @product = create(:product, low_stock_threshold: 10, unit_type: :weight)
          create(:inventory_item, product: @product, quantity: 2)
          create(:inventory_item, product: @product, quantity: 3)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(1)
          row = body.first
          expect(row["product_id"]).to eq(@product.id)
          expect(row["total_quantity"]).to eq(5.0)
          expect(row["low_stock_threshold"]).to eq(10.0)
          expect(row["batches"].length).to eq(2)
        end
      end

      response "200", "includes a product with a threshold but no batches (total = 0)" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          @product = create(:product, low_stock_threshold: 4)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(1)
          row = body.first
          expect(row["product_id"]).to eq(@product.id)
          expect(row["total_quantity"]).to eq(0.0)
          expect(row["batches"]).to eq([])
        end
      end

      response "200", "excludes a product with nil threshold even when stock is zero" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          product = create(:product, low_stock_threshold: nil)
          create(:inventory_item, product: product, quantity: 0)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body).to eq([])
        end
      end

      response "200", "orders most-depleted ratio first" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          @most_depleted = create(:product, name: "Z most depleted", low_stock_threshold: 10, unit_type: :weight)
          create(:inventory_item, product: @most_depleted, quantity: 1)

          @less_depleted = create(:product, name: "A less depleted", low_stock_threshold: 5, unit_type: :weight)
          create(:inventory_item, product: @less_depleted, quantity: 4)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |r| r["product_id"] }).to eq([ @most_depleted.id, @less_depleted.id ])
        end
      end

      response "200", "tiebreaks equal ratios by product name ASC" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          @apple = create(:product, name: "Apple", low_stock_threshold: 10, unit_type: :weight)
          create(:inventory_item, product: @apple, quantity: 2)

          @banana = create(:product, name: "Banana", low_stock_threshold: 5, unit_type: :weight)
          create(:inventory_item, product: @banana, quantity: 1)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |r| r["product_id"] }).to eq([ @apple.id, @banana.id ])
        end
      end

      response "200", "name tiebreak uses pt-BR locale collation (accented chars sort with their base letter)" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          @sabonete = create(:product, name: "Sabonete Líquido Mãos", low_stock_threshold: 10, unit_type: :weight)
          create(:inventory_item, product: @sabonete, quantity: 2)

          @sabao = create(:product, name: "Sabão Líquido", low_stock_threshold: 5, unit_type: :weight)
          create(:inventory_item, product: @sabao, quantity: 1)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |r| r["product_id"] }).to eq([ @sabao.id, @sabonete.id ])
        end
      end

      response "200", "orders nested batches by expiration_date ASC NULLS LAST, created_at ASC" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          product = create(:product, low_stock_threshold: 100, unit_type: :weight)
          @later  = create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 5)
          @sooner = create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 1)
          @nodate = create(:inventory_item, product: product, quantity: 1, expiration_date: nil)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(1)
          ids = body.first["batches"].map { |b| b["id"] }
          expect(ids).to eq([ @sooner.id, @later.id, @nodate.id ])
        end
      end

      response "200", "returns [] when no low-stock products exist" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          ok = create(:product, low_stock_threshold: 1)
          create(:inventory_item, product: ok, quantity: 5)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body).to eq([])
        end
      end

      response "200", "response shape has the six required keys per row and the three required keys per batch" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_low_stock_item" }

        before do
          product = create(:product, low_stock_threshold: 10, unit_type: :weight)
          create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 2)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          row = body.first
          expect(row.keys).to match_array(%w[product_id product_name unit_type total_quantity low_stock_threshold batches])
          batch = row["batches"].first
          expect(batch.keys).to match_array(%w[id quantity expiration_date])
        end
      end
    end
  end
end
