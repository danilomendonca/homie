require "rails_helper"

# Cross-cutting input-bound regressions, deliberately plain request specs rather
# than rswag blocks: every case here returns one of the envelopes those endpoints
# already document, so they add coverage without adding operations to the
# contract.
RSpec.describe "Api::V1 input bounds", type: :request do
  describe "repeated query params" do
    # A repeated param (?limit[]=5) arrives as an Array, which does not answer
    # match? — every regex-then-range parse helper used to 500 on it.
    it "rejects an array-valued limit on GET /v1/inventory/sample" do
      get "/v1/inventory/sample", params: { limit: [ "5" ] }

      expect(response).to have_http_status(400)
      expect(JSON.parse(response.body)["errors"].first["message"]).to match(/between 1 and 100/)
    end

    it "rejects an array-valued limit on GET /v1/products/search" do
      get "/v1/products/search", params: { q: "arroz", limit: [ "5" ] }

      expect(response).to have_http_status(400)
      expect(JSON.parse(response.body)["errors"].first["message"]).to match(/between 1 and 100/)
    end

    it "rejects an array-valued min_similarity on GET /v1/products/search" do
      get "/v1/products/search", params: { q: "arroz", min_similarity: [ "0.5" ] }

      expect(response).to have_http_status(400)
      expect(JSON.parse(response.body)["errors"].first["message"]).to match(/min_similarity/)
    end

    it "rejects an array-valued days on GET /v1/inventory/near_expiration" do
      get "/v1/inventory/near_expiration", params: { days: [ "5" ] }

      expect(response).to have_http_status(400)
      expect(JSON.parse(response.body)["errors"].first["message"]).to match(/`days`/)
    end
  end

  describe "numeric(12,3) ceilings" do
    let(:over) { "1000000000" }             # one past the column's 9 integer digits
    let(:at_ceiling) { "999999999.999" }

    it "rejects an over-large quantity on POST /v1/inventory_items with a 422, not a 500" do
      product = create(:product, unit_type: :weight)

      post "/v1/inventory_items", params: { product_id: product.id, quantity: over }, as: :json

      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)["errors"].map { |e| e["field"] }).to include("quantity")
      expect(InventoryItem.count).to eq(0)
    end

    it "accepts a quantity exactly at the ceiling" do
      product = create(:product, unit_type: :weight)

      post "/v1/inventory_items", params: { product_id: product.id, quantity: at_ceiling }, as: :json

      expect(response).to have_http_status(201)
      expect(InventoryItem.sole.quantity).to eq(BigDecimal(at_ceiling))
    end

    it "reports an over-large quantity per index on POST /v1/inventory_items/bulk" do
      ok = create(:product, name: "Fine", unit_type: :weight)
      bad = create(:product, name: "Over", unit_type: :weight)

      post "/v1/inventory_items/bulk", params: {
        inventory_items: [
          { product_id: ok.id, quantity: 1 },
          { product_id: bad.id, quantity: over }
        ]
      }, as: :json

      expect(response).to have_http_status(422)
      failed = JSON.parse(response.body)["failed"]
      expect(failed.map { |f| f["index"] }).to eq([ 1 ])
      expect(failed.first["errors"].map { |e| e["field"] }).to include("quantity")
      # All-or-nothing: the valid first line persisted nothing either.
      expect(InventoryItem.count).to eq(0)
    end

    it "flags every line that merged into an over-large batch, not just the last one" do
      # The bulk path is additive and groups by (product_id, expiration_date), so
      # it is the *summed* batch that overflows. Both contributing lines are
      # implicated, because neither is individually wrong.
      product = create(:product, unit_type: :weight)

      post "/v1/inventory_items/bulk", params: {
        inventory_items: [
          { product_id: product.id, quantity: "600000000" },
          { product_id: product.id, quantity: "600000000" }
        ]
      }, as: :json

      expect(response).to have_http_status(422)
      failed = JSON.parse(response.body)["failed"]
      expect(failed.map { |f| f["index"] }).to eq([ 0, 1 ])
      expect(failed.map { |f| f["errors"].map { |e| e["field"] } }.flatten.uniq).to eq([ "quantity" ])
      expect(InventoryItem.count).to eq(0)
    end

    it "rejects an over-large low_stock_threshold on POST /v1/products with a 422, not a 500" do
      post "/v1/products", params: {
        name: "Arroz", unit_type: "weight", low_stock_threshold: over
      }, as: :json

      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)["errors"].map { |e| e["field"] }).to include("low_stock_threshold")
      expect(Product.count).to eq(0)
    end
  end

  describe "non-object elements in a bulk body" do
    it "reports a non-object receipt line on POST /v1/inventory/import rather than 500ing" do
      create(:product, name: "Leite Integral", unit_type: :volume)

      post "/v1/inventory/import", params: {
        items: [ "arroz", { name: "Leite Integral", quantity: 1 } ]
      }, as: :json

      expect(response).to have_http_status(200)
      body = JSON.parse(response.body)
      # The bare string carries no name, so it resolves to nothing and is skipped
      # like any other unmatched line — it does not fail the valid line beside it.
      expect(body["unmatched"].map { |u| u["index"] }).to eq([ 0 ])
      expect(body["matched"].map { |m| m["index"] }).to eq([ 1 ])
      expect(InventoryItem.sole.quantity).to eq(1)
    end
  end
end
