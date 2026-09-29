require "swagger_helper"

RSpec.describe "Api::V1::Inventory consume", type: :request do
  path "/v1/inventory/consume" do
    post "Removes consumed stock per product, without naming a batch" do
      tags "Inventory"
      consumes "application/json"
      produces "application/json"
      description <<~DESC.squish
        Subtracts a stated quantity per product, draining its batches FEFO
        (earliest expiration first, expired batches included, the undated default
        batch last) and deleting every batch of a touched product left at zero.
        Lines naming the same product are summed — two consumption events are two
        facts. Consuming more than the product's stock on hand is a per-index 422
        on every line naming that product, with the stock on hand in the message;
        it never clamps at zero, because the mismatch is drift and POST
        /v1/inventory/verify is the call that corrects it. Returns each distinct
        product's remaining total_quantity, in order of first appearance. Does
        not touch stock_verified_at: using stock does not confirm a count.
        All-or-nothing. NOT IDEMPOTENT (PRD §15): a retried request removes the
        stock twice, so do not retry blindly after a timeout — read GET
        /v1/inventory first.
      DESC
      parameter name: :payload, in: :body,
        schema: { "$ref" => "#/components/schemas/inventory_consume_request" }

      # ------------------------------------------------------------------- FEFO

      response "200", "drains FEFO across dated batches and then the default batch" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @product = create(:product, unit_type: :weight)
          @early   = create(:inventory_item, product: @product, quantity: 3, expiration_date: Date.current + 2)
          @late    = create(:inventory_item, product: @product, quantity: 2, expiration_date: Date.current + 10)
          @undated = create(:inventory_item, product: @product, quantity: 4, expiration_date: nil)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 6 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body))
            .to eq({ "consumed" => [ { "product_id" => @product.id, "total_quantity" => 3.0 } ] })
          expect(InventoryItem.exists?(@early.id)).to be(false)
          expect(InventoryItem.exists?(@late.id)).to be(false)
          expect(@undated.reload.quantity).to eq(3)
        end
      end

      response "200", "leaves the remainder on the first batch when it covers the amount" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @product = create(:product, unit_type: :weight)
          @early   = create(:inventory_item, product: @product, quantity: 5, expiration_date: Date.current + 2)
          @undated = create(:inventory_item, product: @product, quantity: 4, expiration_date: nil)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 2 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["consumed"].first["total_quantity"]).to eq(7.0)
          expect(@early.reload.quantity).to eq(3)
          expect(@undated.reload.quantity).to eq(4)
        end
      end

      response "200", "drains an expired batch first without a 422" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @product = create(:product, unit_type: :weight)
          @expired = create(:inventory_item, product: @product, quantity: 3, expiration_date: Date.current + 1)
          @expired.update_column(:expiration_date, Date.current - 3)
          @fresh = create(:inventory_item, product: @product, quantity: 3, expiration_date: Date.current + 5)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 2 } ] } }

        run_test! do |_response|
          expect(@expired.reload.quantity).to eq(1)
          expect(@fresh.reload.quantity).to eq(3)
        end
      end

      response "200", "consuming exactly the stock on hand deletes every batch but keeps the product" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @product = create(:product, unit_type: :weight)
          create(:inventory_item, product: @product, quantity: 3, expiration_date: Date.current + 2)
          create(:inventory_item, product: @product, quantity: 4, expiration_date: nil)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 7 } ] } }

        run_test! do |consume_response|
          expect(JSON.parse(consume_response.body)["consumed"].first["total_quantity"]).to eq(0.0)
          expect(@product.inventory_items.count).to eq(0)

          get "/v1/inventory", params: { include_empty: "true" }
          row = JSON.parse(response.body).find { |r| r["product_id"] == @product.id }
          expect(row["batches"]).to eq([])
        end
      end

      response "200", "sweeps a zero-quantity row that was already there" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @product = create(:product, unit_type: :weight)
          @stray   = create(:inventory_item, product: @product, quantity: 0, expiration_date: Date.current + 9)
          @undated = create(:inventory_item, product: @product, quantity: 4, expiration_date: nil)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 1 } ] } }

        run_test! do |_response|
          expect(InventoryItem.exists?(@stray.id)).to be(false)
          expect(@undated.reload.quantity).to eq(3)
        end
      end

      # ------------------------------------------------------------ duplicates

      response "200", "sums duplicate lines and reports the product once" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @product = create(:product, unit_type: :weight)
          @undated = create(:inventory_item, product: @product, quantity: 5)
        end

        let(:payload) do
          { items: [ { product_id: @product.id, quantity: 2 }, { product_id: @product.id.upcase, quantity: 2 } ] }
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["consumed"])
            .to eq([ { "product_id" => @product.id, "total_quantity" => 1.0 } ])
          expect(@undated.reload.quantity).to eq(1)
        end
      end

      response "422", "fails every duplicate line when their sum exceeds stock on hand" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before do
          @product = create(:product, unit_type: :weight)
          @undated = create(:inventory_item, product: @product, quantity: 5)
        end

        let(:payload) do
          { items: [ { product_id: @product.id, quantity: 3 }, { product_id: @product.id, quantity: 3 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].map { |f| f["index"] }).to eq([ 0, 1 ])
          expect(body["failed"].first["errors"])
            .to eq([ { "field" => "quantity", "message" => "exceeds stock on hand (5.0) for this product" } ])
          expect(@undated.reload.quantity).to eq(5)
        end
      end

      response "200", "reports two products in request order" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @rice  = create(:product, name: "Arroz", unit_type: :weight)
          @beans = create(:product, name: "Feijão", unit_type: :weight)
          create(:inventory_item, product: @rice, quantity: 5)
          create(:inventory_item, product: @beans, quantity: 2)
        end

        let(:payload) do
          { items: [ { product_id: @beans.id, quantity: 2 }, { product_id: @rice.id, quantity: 1 } ] }
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["consumed"]).to eq([
            { "product_id" => @beans.id, "total_quantity" => 0.0 },
            { "product_id" => @rice.id, "total_quantity" => 4.0 }
          ])
        end
      end

      # --------------------------------------------------------- over-consumption

      response "422", "rejects over-consumption with the stock on hand, rolling back every line" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before do
          @other   = create(:product, unit_type: :weight)
          @product = create(:product, unit_type: :weight)
          @other_batch = create(:inventory_item, product: @other, quantity: 5)
          @batch       = create(:inventory_item, product: @product, quantity: 2)
        end

        let(:payload) do
          { items: [ { product_id: @other.id, quantity: 1 }, { product_id: @product.id, quantity: 3 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].map { |f| f["index"] }).to eq([ 1 ])
          expect(body["failed"].first["errors"])
            .to eq([ { "field" => "quantity", "message" => "exceeds stock on hand (2.0) for this product" } ])
          expect(@other_batch.reload.quantity).to eq(5)
          expect(@batch.reload.quantity).to eq(2)
        end
      end

      response "422", "rejects consuming a product with no batches at all" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) { { items: [ { product_id: @product.id, quantity: 1 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["failed"].first["errors"])
            .to eq([ { "field" => "quantity", "message" => "exceeds stock on hand (0.0) for this product" } ])
        end
      end

      # --------------------------------------------------------- stock_verified_at

      response "200", "leaves stock_verified_at untouched" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        before do
          @never   = create(:product, unit_type: :weight)
          @counted = create(:product, unit_type: :weight)
          @counted.update_column(:stock_verified_at, 3.days.ago)
          @previous = @counted.reload.stock_verified_at
          create(:inventory_item, product: @never, quantity: 5)
          create(:inventory_item, product: @counted, quantity: 5)
        end

        let(:payload) do
          { items: [ { product_id: @never.id, quantity: 1 }, { product_id: @counted.id, quantity: 1 } ] }
        end

        run_test! do |_response|
          expect(@never.reload.stock_verified_at).to be_nil
          expect(@counted.reload.stock_verified_at).to eq(@previous)
        end
      end

      # -------------------------------------------------------------- per-line

      response "422", "rejects zero, negative and non-numeric quantities per index" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before do
          @product = create(:product, unit_type: :weight)
          create(:inventory_item, product: @product, quantity: 5)
        end

        let(:payload) do
          {
            items: [
              { product_id: @product.id, quantity: 0 },
              { product_id: @product.id, quantity: -1 },
              { product_id: @product.id, quantity: "abc" }
            ]
          }
        end

        run_test! do |response|
          messages = JSON.parse(response.body)["failed"].map { |f| f["errors"].map { |e| e["message"] } }
          expect(messages).to eq([
            [ "must be greater than 0" ], [ "must be greater than 0" ], [ "is not a number" ]
          ])
        end
      end

      response "422", "rejects a fractional quantity on a unit product" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before do
          @product = create(:product, unit_type: :unit)
          create(:inventory_item, product: @product, quantity: 5)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 1.5 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["failed"].first["errors"]).to eq([
            { "field" => "quantity", "message" => "must be a whole number when product unit_type is 'unit'" }
          ])
        end
      end

      response "422", "reports unknown and malformed product_ids per index, not as a 404" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        let(:payload) do
          { items: [ { product_id: SecureRandom.uuid, quantity: 1 }, { product_id: "not-a-uuid", quantity: 1 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].map { |f| f["index"] }).to eq([ 0, 1 ])
          body["failed"].each do |failure|
            expect(failure["errors"])
              .to eq([ { "field" => "product_id", "message" => "must reference an existing product" } ])
          end
        end
      end

      response "422", "reports a non-object element per index rather than raising" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        let(:payload) { { items: [ "arroz" ] } }

        run_test! do |response|
          failure = JSON.parse(response.body)["failed"].first
          expect(failure["index"]).to eq(0)
          expect(failure["input"]).to eq({})
        end
      end

      # ---------------------------------------------------------------- envelope

      response "200", "accepts an empty items array" do
        schema "$ref" => "#/components/schemas/inventory_consume_response"

        let(:payload) { { items: [] } }

        run_test! do |response|
          expect(JSON.parse(response.body)).to eq({ "consumed" => [] })
        end
      end

      response "400", "rejects a body without items" do
        schema "$ref" => "#/components/schemas/error_envelope"

        let(:payload) { {} }

        run_test!
      end

      response "400", "rejects items that is not an array" do
        schema "$ref" => "#/components/schemas/error_envelope"

        let(:payload) { { items: "arroz" } }

        run_test!
      end

      response "400", "rejects an items array exceeding the limit" do
        schema "$ref" => "#/components/schemas/error_envelope"

        before do
          @product = create(:product, unit_type: :weight)
          @batch = create(:inventory_item, product: @product, quantity: 1000)
        end

        let(:payload) { { items: Array.new(501) { { product_id: @product.id, quantity: 1 } } } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to match(/maximum of 500/)
          expect(@batch.reload.quantity).to eq(1000)
        end
      end
    end
  end
end
