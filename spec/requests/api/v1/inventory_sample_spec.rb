require "swagger_helper"

RSpec.describe "Api::V1::Inventory sample", type: :request do
  path "/v1/inventory/sample" do
    get "Lists the products most overdue for a stock count" do
      tags "Inventory"
      produces "application/json"
      description <<~DESC.squish
        Returns products ordered least-recently-verified first — never-verified
        products (stock_verified_at null) lead, then oldest first, with the pt-BR
        collation on the product name as the tiebreak. Every product is a
        candidate, including ones with no batches and ones whose batches sum to
        zero: "did I actually run out of rice?" is exactly what a count answers.
        total_quantity is the quantity the API currently believes, to put in the
        question; low_stock_threshold lets the caller flag the answer without a
        second request. Write the answers back with POST /v1/inventory/verify.
      DESC
      parameter name: :limit, in: :query, type: :string, required: false

      # NOTE: defining a `let` makes rswag send `limit=<value>` (even when
      # nil → `limit=`). Tests for an *absent* param therefore omit the let.

      response "200", "orders never-verified products ahead of previously-verified ones" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"

        before do
          @recent = create(:product, name: "Recently counted")
          @recent.update_column(:stock_verified_at, 1.hour.ago)
          @stale = create(:product, name: "Stale count")
          @stale.update_column(:stock_verified_at, 30.days.ago)
          @never = create(:product, name: "Never counted")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["items"].map { |i| i["product_id"] })
            .to eq([ @never.id, @stale.id, @recent.id ])
          expect(body["items"].first["stock_verified_at"]).to be_nil
          expect(body["items"].last["stock_verified_at"]).to be_present
        end
      end

      response "200", "breaks ties on stock_verified_at with the pt-BR collation" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"

        before do
          # Both never verified, so name is the only discriminator. The default
          # Postgres collation sorts "Açúcar" by codepoint, after the ASCII
          # alphabet — this ordering must not regress to that.
          create(:product, name: "Arroz")
          create(:product, name: "Açúcar")
          create(:product, name: "Banana")
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["items"].map { |i| i["product_name"] })
            .to eq([ "Açúcar", "Arroz", "Banana" ])
        end
      end

      response "200", "includes products with no batches and products whose batches sum to zero" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"

        before do
          @no_batches = create(:product, name: "A never stocked")
          @all_zero   = create(:product, name: "B all zero")
          create(:inventory_item, product: @all_zero, quantity: 0)
        end

        run_test! do |response|
          rows = JSON.parse(response.body)["items"].index_by { |i| i["product_id"] }
          expect(rows.keys).to contain_exactly(@no_batches.id, @all_zero.id)
          expect(rows[@no_batches.id]["total_quantity"]).to eq(0.0)
          expect(rows[@all_zero.id]["total_quantity"]).to eq(0.0)
        end
      end

      response "200", "reports the aggregated quantity across a product's batches" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"

        before do
          @product = create(:product, name: "Arroz", unit_type: :weight, low_stock_threshold: 1000)
          create(:inventory_item, product: @product, quantity: 400)
          create(:inventory_item, product: @product, quantity: 350, expiration_date: Date.current + 5)
        end

        run_test! do |response|
          row = JSON.parse(response.body)["items"].first
          expect(row["total_quantity"]).to eq(750.0)
          expect(row["low_stock_threshold"]).to eq(1000.0)
          expect(row["unit_type"]).to eq("weight")
          expect(row).not_to have_key("batches")
        end
      end

      response "200", "reports a null low_stock_threshold for a product without one" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"

        before { create(:product, name: "Sabão", low_stock_threshold: nil) }

        run_test! do |response|
          expect(JSON.parse(response.body)["items"].first["low_stock_threshold"]).to be_nil
        end
      end

      response "200", "defaults to 20 items" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"

        before { 25.times { |n| create(:product, name: format("Product %02d", n)) } }

        run_test! do |response|
          expect(JSON.parse(response.body)["items"].length).to eq(20)
        end
      end

      response "200", "honors an explicit limit" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"
        let(:limit) { "3" }

        before { 5.times { |n| create(:product, name: "Product #{n}") } }

        run_test! do |response|
          expect(JSON.parse(response.body)["items"].length).to eq(3)
        end
      end

      response "200", "returns an empty items array when the catalogue is empty" do
        schema "$ref" => "#/components/schemas/inventory_sample_response"

        run_test! do |response|
          expect(JSON.parse(response.body)["items"]).to eq([])
        end
      end

      response "400", "rejects limit 0" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:limit) { "0" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"])
            .to match(/`limit`: must be an integer between 1 and 100/)
        end
      end

      response "400", "rejects a limit above the maximum" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:limit) { "101" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to match(/between 1 and 100/)
        end
      end

      response "400", "rejects a non-numeric limit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:limit) { "abc" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to match(/between 1 and 100/)
        end
      end
    end
  end
end
