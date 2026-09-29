require "swagger_helper"

RSpec.describe "Api::V1::Inventory verify", type: :request do
  path "/v1/inventory/verify" do
    post "Writes counted stock levels back against products" do
      tags "Inventory"
      consumes "application/json"
      produces "application/json"
      description <<~DESC.squish
        Records an absolute counted quantity per product and stamps
        stock_verified_at. The timestamp advances even when the count matches what
        the API already believed — without that, a product that is always right is
        indistinguishable from one that has never been counted and the sample
        re-surfaces it forever. Reconciliation against a product's batches: a
        decrease drains FEFO (earliest expiration first, undated batches last) and
        deletes every batch left at zero; an increase lands in the product's
        undated (expiration_date null) batch, creating it if absent, because an
        increase means an unrecorded purchase whose date is unknown and dating it
        on a guess would make near_expiration report the new stock as expiring; a
        count of zero deletes every batch. A partial reply is normal — only the
        products in the body are touched, and the rest keep their timestamp and
        stay at the front of the next sample. All-or-nothing: any per-index
        failure rolls the whole request back. The follow-up read is GET
        /v1/inventory.
      DESC
      parameter name: :payload, in: :body,
        schema: { "$ref" => "#/components/schemas/inventory_verify_request" }

      # ------------------------------------------------------------- the invariant

      response "200", "stamps stock_verified_at when the count was already correct, writing no quantity" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @batch = create(:inventory_item, product: @product, quantity: 4)
          @batch.update_column(:updated_at, 1.day.ago)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 4 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)).to eq({ "verified" => 1 })
          expect(@product.reload.stock_verified_at).to be_present
          # The stocked batch, specifically: the zero sweep may still fire on a
          # stray row elsewhere, so this is the assertion rather than a query count.
          expect(@batch.reload.quantity).to eq(4)
          expect(@batch.updated_at).to be < 1.hour.ago
        end
      end

      response "200", "advances an existing stock_verified_at to a newer one" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @never = create(:product, name: "Never counted", unit_type: :weight)
          @old   = create(:product, name: "Counted long ago", unit_type: :weight)
          @old.update_column(:stock_verified_at, 30.days.ago)
          @previous = @old.reload.stock_verified_at
        end

        let(:payload) do
          { items: [ { product_id: @never.id, quantity: 1 }, { product_id: @old.id, quantity: 1 } ] }
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["verified"]).to eq(2)
          expect(@never.reload.stock_verified_at).to be_present
          expect(@old.reload.stock_verified_at).to be > @previous
        end
      end

      # ----------------------------------------------------------- reconciliation

      response "200", "drains FEFO across two batches, deleting the one it empties" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @early = create(:inventory_item, product: @product, quantity: 3,
            expiration_date: Date.current + 2)
          @late = create(:inventory_item, product: @product, quantity: 2,
            expiration_date: Date.current + 10)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 2 } ] } }

        run_test! do |_response|
          expect(InventoryItem.exists?(@early.id)).to be(false)
          expect(@late.reload.quantity).to eq(2)
        end
      end

      response "200", "leaves the remainder on a partially drained batch" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @batch = create(:inventory_item, product: @product, quantity: 900)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 650 } ] } }

        run_test! do |_response|
          expect(@batch.reload.quantity).to eq(650)
        end
      end

      response "200", "drains undated batches last" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @dated = create(:inventory_item, product: @product, quantity: 2,
            expiration_date: Date.current + 5)
          @undated = create(:inventory_item, product: @product, quantity: 2, expiration_date: nil)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 3 } ] } }

        run_test! do |_response|
          expect(@dated.reload.quantity).to eq(1)
          expect(@undated.reload.quantity).to eq(2)
        end
      end

      response "200", "drains an expired batch, since the date rule is create-context only" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @batch = create(:inventory_item, product: @product, quantity: 500)
          # Counting down a product whose stock went bad is exactly when verify is
          # most needed, so this must not 422.
          @batch.update_column(:expiration_date, Date.current - 3)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 200 } ] } }

        run_test! do |_response|
          expect(@batch.reload.quantity).to eq(200)
        end
      end

      response "200", "creates an undated batch when the product has none" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) { { items: [ { product_id: @product.id, quantity: 750 } ] } }

        run_test! do |_response|
          batch = @product.inventory_items.sole
          expect(batch.quantity).to eq(750)
          expect(batch.expiration_date).to be_nil
        end
      end

      response "200", "puts an increase in a new undated batch, leaving dated batches alone" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @dated = create(:inventory_item, product: @product, quantity: 2,
            expiration_date: Date.current + 30)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 5 } ] } }

        run_test! do |_response|
          # Not merged into the dated batch: that would claim the newly counted
          # stock expires in 30 days on the strength of a guess.
          expect(@dated.reload.quantity).to eq(2)
          undated = @product.inventory_items.where(expiration_date: nil).sole
          expect(undated.quantity).to eq(3)
        end
      end

      response "200", "reuses the existing undated batch rather than creating a second one" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @undated = create(:inventory_item, product: @product, quantity: 1, expiration_date: nil)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 4 } ] } }

        run_test! do |_response|
          expect(@product.inventory_items.count).to eq(1)
          expect(@undated.reload.quantity).to eq(4)
        end
      end

      response "200", "deletes every batch when counted to zero, including one already at zero" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          create(:inventory_item, product: @product, quantity: 3)
          create(:inventory_item, product: @product, quantity: 0, expiration_date: Date.current + 5)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 0 } ] } }

        run_test! do |_response|
          expect(@product.inventory_items.count).to eq(0)
          expect(@product.reload.stock_verified_at).to be_present
        end
      end

      response "200", "confirms a product with no batches is genuinely out of stock" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        # "Did I actually run out of rice?" — the question the whole phase is
        # shaped around, and the reason the timestamp lives on products: a product
        # with zero batches has no batch row to stamp. counted == current == 0, so
        # nothing is written and no batch is invented; only the timestamp moves.
        before { @product = create(:product, unit_type: :weight) }

        let(:payload) { { items: [ { product_id: @product.id, quantity: 0 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)).to eq({ "verified" => 1 })
          expect(@product.inventory_items.count).to eq(0)
          expect(@product.reload.stock_verified_at).to be_present
        end
      end

      response "200", "sweeps a zero row the count never drained" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @product = create(:product, unit_type: :weight)
          @stray = create(:inventory_item, product: @product, quantity: 0, expiration_date: nil)
          @stocked = create(:inventory_item, product: @product, quantity: 5,
            expiration_date: Date.current + 2)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 3 } ] } }

        run_test! do |_response|
          # No dead row survives for ?include_empty=true to report, however it got
          # to zero (Phase 8's rule).
          expect(@product.inventory_items.pluck(:id)).to eq([ @stocked.id ])
          expect(@stocked.reload.quantity).to eq(3)
        end
      end

      response "200", "sweeps a stray zero row even when the count was already correct" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          # The intersection of the two rules: the equal-count branch writes no
          # quantity, but the sweep still fires. Asserting the *stocked* batch is
          # untouched is what pins "no quantity writes" — a zero query count would
          # contradict the sweep and be wrong.
          @product = create(:product, unit_type: :weight)
          @stray = create(:inventory_item, product: @product, quantity: 0, expiration_date: nil)
          @stocked = create(:inventory_item, product: @product, quantity: 5,
            expiration_date: Date.current + 2)
          @stocked.update_column(:updated_at, 1.day.ago)
        end

        let(:payload) { { items: [ { product_id: @product.id, quantity: 5 } ] } }

        run_test! do |_response|
          expect(InventoryItem.exists?(@stray.id)).to be(false)
          expect(@stocked.reload.quantity).to eq(5)
          expect(@stocked.updated_at).to be < 1.hour.ago
          expect(@product.reload.stock_verified_at).to be_present
        end
      end

      # -------------------------------------------------------- request semantics

      response "200", "touches only the products in the body (partial reply)" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @answered = create(:product, name: "Answered", unit_type: :weight)
          create(:inventory_item, product: @answered, quantity: 5)
          @ignored = create(:product, name: "Ignored", unit_type: :weight)
          @ignored_batch = create(:inventory_item, product: @ignored, quantity: 9)
        end

        let(:payload) { { items: [ { product_id: @answered.id, quantity: 2 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["verified"]).to eq(1)
          expect(@answered.reload.stock_verified_at).to be_present
          expect(@ignored.reload.stock_verified_at).to be_nil
          expect(@ignored_batch.reload.quantity).to eq(9)
        end
      end

      response "200", "counts every product in the body, including the unchanged ones" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before do
          @unchanged = create(:product, name: "Unchanged", unit_type: :weight)
          create(:inventory_item, product: @unchanged, quantity: 3)
          @changed = create(:product, name: "Changed", unit_type: :weight)
          create(:inventory_item, product: @changed, quantity: 3)
        end

        let(:payload) do
          {
            items: [
              { product_id: @unchanged.id, quantity: 3 },
              { product_id: @changed.id, quantity: 1 }
            ]
          }
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["verified"]).to eq(2)
        end
      end

      response "200", "verifies the product named by an uppercase UUID" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) { { items: [ { product_id: @product.id.upcase, quantity: 2 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["verified"]).to eq(1)
          expect(@product.reload.stock_verified_at).to be_present
        end
      end

      response "200", "accepts an empty items array as a request that verifies nothing" do
        schema "$ref" => "#/components/schemas/inventory_verify_response"
        let(:payload) { { items: [] } }

        run_test! do |response|
          expect(JSON.parse(response.body)).to eq({ "verified" => 0 })
        end
      end

      # ---------------------------------------------------------------- failures

      response "422", "rejects a duplicated product_id on its second occurrence, writing nothing" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before do
          @product = create(:product, unit_type: :weight)
          @batch = create(:inventory_item, product: @product, quantity: 5)
        end

        let(:payload) do
          {
            items: [
              { product_id: @product.id, quantity: 1 },
              { product_id: @product.id, quantity: 2 }
            ]
          }
        end

        run_test! do |response|
          failed = JSON.parse(response.body)["failed"]
          expect(failed.map { |f| f["index"] }).to eq([ 1 ])
          expect(failed.first["errors"])
            .to eq([ { "field" => "product_id",
                       "message" => "is duplicated within verify request" } ])
          expect(@batch.reload.quantity).to eq(5)
          expect(@product.reload.stock_verified_at).to be_nil
        end
      end

      response "422", "treats the same UUID in two cases as a duplicate" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) do
          {
            items: [
              { product_id: @product.id, quantity: 1 },
              { product_id: @product.id.upcase, quantity: 2 }
            ]
          }
        end

        run_test! do |response|
          # Postgres compares uuids case-insensitively, so these are one product;
          # left unflagged, the two absolute counts would race.
          expect(JSON.parse(response.body)["failed"].map { |f| f["index"] }).to eq([ 1 ])
          expect(@product.reload.stock_verified_at).to be_nil
        end
      end

      response "422", "rejects a fractional count on a unit_type=unit product and rolls the request back" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before do
          @weight = create(:product, name: "Rice", unit_type: :weight)
          @weight_batch = create(:inventory_item, product: @weight, quantity: 1000)
          @unit = create(:product, name: "Eggs", unit_type: :unit)
        end

        let(:payload) do
          {
            items: [
              { product_id: @weight.id, quantity: 500 },
              { product_id: @unit.id, quantity: 1.5 }
            ]
          }
        end

        run_test! do |response|
          failed = JSON.parse(response.body)["failed"]
          expect(failed.map { |f| f["index"] }).to eq([ 1 ])
          expect(failed.first["errors"]).to eq([
            { "field" => "quantity",
              "message" => "must be a whole number when product unit_type is 'unit'" }
          ])
          # The earlier, valid line persisted nothing.
          expect(@weight_batch.reload.quantity).to eq(1000)
          expect(@weight.reload.stock_verified_at).to be_nil
        end
      end

      response "422", "reports an unknown product_id per index rather than as a 404" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        let(:payload) { { items: [ { product_id: SecureRandom.uuid, quantity: 1 } ] } }

        run_test! do |response|
          failed = JSON.parse(response.body)["failed"]
          expect(failed.first["index"]).to eq(0)
          expect(failed.first["errors"])
            .to eq([ { "field" => "product_id",
                       "message" => "must reference an existing product" } ])
        end
      end

      response "422", "reports a malformed UUID the same way" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        let(:payload) { { items: [ { product_id: "not-a-uuid", quantity: 1 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["failed"].first["errors"].map { |e| e["field"] })
            .to eq([ "product_id" ])
        end
      end

      response "422", "rejects a negative quantity" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) { { items: [ { product_id: @product.id, quantity: -1 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["failed"].first["errors"])
            .to eq([ { "field" => "quantity",
                       "message" => "must be greater than or equal to 0" } ])
        end
      end

      response "422", "rejects a count past the quantity column's ceiling" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { @product = create(:product, unit_type: :weight) }

        # StockReconciler#failures never instantiates an InventoryItem, so this
        # check lives there rather than being inherited from the model
        # validation. Without it the count reaches save! and raises RangeError —
        # a 500 instead of this envelope.
        let(:payload) { { items: [ { product_id: @product.id, quantity: "1000000000" } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["failed"].first["errors"])
            .to eq([ { "field" => "quantity",
                       "message" => "must be less than or equal to 999999999.999" } ])
          expect(@product.inventory_items.count).to eq(0)
          expect(@product.reload.stock_verified_at).to be_nil
        end
      end

      response "422", "rejects a non-numeric quantity" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) { { items: [ { product_id: @product.id, quantity: "muitos" } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["failed"].first["errors"])
            .to eq([ { "field" => "quantity", "message" => "is not a number" } ])
        end
      end

      response "422", "rejects a missing quantity" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) { { items: [ { product_id: @product.id } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["failed"].first["errors"])
            .to eq([ { "field" => "quantity", "message" => "can't be blank" } ])
        end
      end

      response "422", "reports a non-object element as a per-index failure rather than a 500" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        let(:payload) { { items: [ "arroz" ] } }

        run_test! do |response|
          failed = JSON.parse(response.body)["failed"]
          expect(failed.first["index"]).to eq(0)
          expect(failed.first["input"]).to eq({})
          expect(failed.first["errors"].map { |e| e["field"] })
            .to contain_exactly("quantity", "product_id")
        end
      end

      response "400", "rejects a body without an items key" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { {} }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to be_present
        end
      end

      response "400", "rejects items that is not an array" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { items: "not an array" } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to be_present
        end
      end

      response "400", "rejects an items array over the limit" do
        schema "$ref" => "#/components/schemas/error_envelope"

        before { @product = create(:product, unit_type: :weight) }

        let(:payload) do
          { items: Array.new(501) { { product_id: @product.id, quantity: 1 } } }
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to match(/maximum of 500/)
          expect(@product.reload.stock_verified_at).to be_nil
        end
      end
    end
  end
end
