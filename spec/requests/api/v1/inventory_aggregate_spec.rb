require "swagger_helper"

RSpec.describe "Api::V1::InventoryAggregate", type: :request do
  path "/v1/inventory" do
    get "Lists products with aggregated stock and nested batches" do
      tags "Inventory"
      produces "application/json"
      parameter name: :include_empty, in: :query, type: :string, required: false

      response "200", "default (include_empty absent) returns only stocked products" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { nil }

        before do
          @stocked = create(:product, name: "Stocked")
          create(:inventory_item, product: @stocked, quantity: 3)

          zero_batches = create(:product, name: "AllZero")
          create(:inventory_item, product: zero_batches, quantity: 0)

          create(:product, name: "NoBatches")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(1)
          expect(body.first["product_id"]).to eq(@stocked.id)
          expect(body.first["total_quantity"]).to eq(3.0)
        end
      end

      response "200", "include_empty=true includes products with all-zero batches and lists those zero batches" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { "true" }

        before do
          @product = create(:product, name: "AllZero")
          create(:inventory_item, product: @product, quantity: 0)
          create(:inventory_item, product: @product, quantity: 0)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(1)
          row = body.first
          expect(row["product_id"]).to eq(@product.id)
          expect(row["total_quantity"]).to eq(0.0)
          expect(row["batches"].length).to eq(2)
        end
      end

      response "200", "include_empty=true includes never-stocked products with empty batches array" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { "true" }

        before do
          @product = create(:product, name: "NeverStocked")
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

      response "200", "explicit include_empty=false matches the absent-param behavior" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { "false" }

        before do
          @stocked = create(:product, name: "Stocked")
          create(:inventory_item, product: @stocked, quantity: 3)

          zero_batches = create(:product, name: "AllZero")
          create(:inventory_item, product: zero_batches, quantity: 0)

          create(:product, name: "NoBatches")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(1)
          expect(body.first["product_id"]).to eq(@stocked.id)
        end
      end

      response "200", "orders products by product_name ASC" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { "true" }

        before do
          @zebra = create(:product, name: "Zebra")
          @apple = create(:product, name: "Apple")
          @mango = create(:product, name: "Mango")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |r| r["product_id"] }).to eq([ @apple.id, @mango.id, @zebra.id ])
        end
      end

      response "200", "orders product names with pt-BR locale collation (accented chars sort with their base letter)" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { "true" }

        before do
          @sabonete = create(:product, name: "Sabonete Líquido Mãos")
          @sabao    = create(:product, name: "Sabão Líquido")
          @sabao_coco = create(:product, name: "Sabão Líquido Côco")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |r| r["product_id"] }).to eq([ @sabao.id, @sabao_coco.id, @sabonete.id ])
        end
      end

      response "200", "orders nested batches by expiration_date ASC NULLS LAST, created_at ASC" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { "true" }

        before do
          product = create(:product, unit_type: :weight)
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

      response "200", "total_quantity is the sum of batch quantities" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { nil }

        before do
          @product = create(:product, unit_type: :weight)
          create(:inventory_item, product: @product, quantity: 2.5)
          create(:inventory_item, product: @product, quantity: 3.0)
          create(:inventory_item, product: @product, quantity: 0.5)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.length).to eq(1)
          expect(body.first["total_quantity"]).to eq(6.0)
        end
      end

      response "200", "response shape has the five required row keys and three required batch keys; no low_stock_threshold" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { nil }

        before do
          product = create(:product, unit_type: :weight)
          create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 2)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          row = body.first
          expect(row.keys).to match_array(%w[product_id product_name unit_type total_quantity batches])
          expect(row.keys).not_to include("low_stock_threshold")
          batch = row["batches"].first
          expect(batch.keys).to match_array(%w[id quantity expiration_date])
        end
      end

      response "200", "avoids N+1: query count is bounded regardless of product count" do
        schema type: :array, items: { "$ref" => "#/components/schemas/inventory_aggregate_item" }
        let(:include_empty) { "true" }

        before do
          5.times do
            product = create(:product)
            3.times { create(:inventory_item, product: product, quantity: 1) }
          end
        end

        run_test! do |_response|
          queries = []
          callback = lambda do |_name, _start, _finish, _id, payload|
            next if payload[:name].in?(%w[SCHEMA TRANSACTION CACHE])
            next if payload[:sql] =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i
            queries << payload[:sql]
          end

          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            get "/v1/inventory", params: { include_empty: "true" }
          end

          expect(queries.size).to be <= 3
        end
      end
    end
  end
end
