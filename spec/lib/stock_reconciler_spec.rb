require "rails_helper"

# Coverage for the PORO itself, independent of the controller — the mirror of
# spec/lib/inventory_batch_applier_spec.rb for the absolute-count path.
RSpec.describe StockReconciler do
  def entry(index, product_id, quantity)
    {
      index: index,
      raw:   { "product_id" => product_id, "quantity" => quantity },
      permitted: { product_id: product_id, quantity: quantity }
    }
  end

  let(:product) { create(:product, unit_type: :weight) }

  describe "#failures" do
    it "is empty for a well-formed entry" do
      expect(described_class.new([ entry(0, product.id, 5) ]).failures).to eq([])
    end

    it "reports a blank quantity keyed to the caller's index" do
      reconciler = described_class.new([ entry(7, product.id, nil) ])

      expect(reconciler.failures).to eq([
        { index: 7, input: { "product_id" => product.id, "quantity" => nil },
          errors: [ { field: "quantity", message: "can't be blank" } ] }
      ])
    end

    it "reports a negative quantity" do
      expect(described_class.new([ entry(0, product.id, -1) ]).failures.first[:errors])
        .to eq([ { field: "quantity", message: "must be greater than or equal to 0" } ])
    end

    it "reports a non-numeric quantity rather than raising from the BigDecimal cast" do
      expect(described_class.new([ entry(0, product.id, "abc") ]).failures.first[:errors])
        .to eq([ { field: "quantity", message: "is not a number" } ])
    end

    it "reports an unknown product_id as a field error, not by raising" do
      expect(described_class.new([ entry(0, SecureRandom.uuid, 1) ]).failures.first[:errors])
        .to eq([ { field: "product_id", message: "must reference an existing product" } ])
    end

    it "treats a malformed UUID as an unknown product" do
      expect(described_class.new([ entry(0, "not-a-uuid", 1) ]).failures.first[:errors])
        .to eq([ { field: "product_id", message: "must reference an existing product" } ])
    end

    it "flags the second and later occurrences of a duplicated product_id" do
      reconciler = described_class.new([ entry(0, product.id, 1), entry(1, product.id, 2) ])

      expect(reconciler.failures.map { |f| f[:index] }).to eq([ 1 ])
      expect(reconciler.failures.first[:errors])
        .to eq([ { field: "product_id", message: "is duplicated within verify request" } ])
    end

    it "normalizes ids before comparing, so case is not a distinction" do
      # Postgres compares uuids case-insensitively, so an uppercase id is the same
      # product; keying on the raw string would let the two counts race in #apply!.
      reconciler = described_class.new([
        entry(0, product.id, 1), entry(1, product.id.upcase, 2)
      ])

      expect(reconciler.failures.map { |f| f[:index] }).to eq([ 1 ])
    end

    it "does not report an uppercase id as an unknown product" do
      expect(described_class.new([ entry(0, product.id.upcase, 1) ]).failures).to eq([])
    end

    it "rejects a fractional count against a unit_type=unit product" do
      unit_product = create(:product, unit_type: :unit)

      expect(described_class.new([ entry(0, unit_product.id, 1.5) ]).failures.first[:errors])
        .to eq([
          { field: "quantity",
            message: "must be a whole number when product unit_type is 'unit'" }
        ])
    end

    it "rejects a count past InventoryItem::MAX_QUANTITY" do
      expect(described_class.new([ entry(0, product.id, "1000000000") ]).failures.first[:errors])
        .to eq([
          { field: "quantity", message: "must be less than or equal to 999999999.999" }
        ])
    end

    it "allows a count exactly at the ceiling" do
      expect(described_class.new([ entry(0, product.id, "999999999.999") ]).failures).to eq([])
    end

    it "allows a fractional count against a weight product" do
      expect(described_class.new([ entry(0, product.id, 1.5) ]).failures).to eq([])
    end

    it "sorts failures by index" do
      reconciler = described_class.new([ entry(3, product.id, -1), entry(1, "nope", 1) ])

      expect(reconciler.failures.map { |f| f[:index] }).to eq([ 1, 3 ])
    end
  end

  describe "#apply!" do
    it "returns the number of products verified" do
      other = create(:product, unit_type: :weight)

      expect(described_class.new([ entry(0, product.id, 1), entry(1, other.id, 2) ]).apply!).to eq(2)
    end

    it "stamps stock_verified_at even when the count was already correct" do
      batch = create(:inventory_item, product: product, quantity: 4)

      expect {
        described_class.new([ entry(0, product.id, 4) ]).apply!
      }.to change { product.reload.stock_verified_at }.from(nil)

      expect(batch.reload.quantity).to eq(4)
    end

    it "shares one timestamp across every product in the request" do
      other = create(:product, unit_type: :weight)
      described_class.new([ entry(0, product.id, 1), entry(1, other.id, 1) ]).apply!

      expect(product.reload.stock_verified_at).to eq(other.reload.stock_verified_at)
    end

    it "bumps updated_at alongside stock_verified_at" do
      product.update_column(:updated_at, 1.day.ago)

      expect { described_class.new([ entry(0, product.id, 1) ]).apply! }
        .to change { product.reload.updated_at }
    end

    it "drains FEFO, deleting the batch it empties" do
      early = create(:inventory_item, product: product, quantity: 3, expiration_date: Date.current + 2)
      late  = create(:inventory_item, product: product, quantity: 2, expiration_date: Date.current + 10)

      described_class.new([ entry(0, product.id, 2) ]).apply!

      expect(InventoryItem.exists?(early.id)).to be(false)
      expect(late.reload.quantity).to eq(2)
    end

    it "leaves the remainder on a partially drained batch" do
      batch = create(:inventory_item, product: product, quantity: 5)

      described_class.new([ entry(0, product.id, 3) ]).apply!

      expect(batch.reload.quantity).to eq(3)
    end

    it "drains undated batches last" do
      dated   = create(:inventory_item, product: product, quantity: 2, expiration_date: Date.current + 5)
      undated = create(:inventory_item, product: product, quantity: 2, expiration_date: nil)

      described_class.new([ entry(0, product.id, 3) ]).apply!

      expect(dated.reload.quantity).to eq(1)
      expect(undated.reload.quantity).to eq(2)
    end

    it "drains an expired batch without tripping the create-context date validator" do
      batch = create(:inventory_item, product: product, quantity: 5)
      batch.update_column(:expiration_date, Date.current - 3)

      expect { described_class.new([ entry(0, product.id, 2) ]).apply! }.not_to raise_error
      expect(batch.reload.quantity).to eq(2)
    end

    it "creates an undated batch when the product has none" do
      described_class.new([ entry(0, product.id, 7) ]).apply!

      expect(product.inventory_items.count).to eq(1)
      batch = product.inventory_items.first
      expect(batch.quantity).to eq(7)
      expect(batch.expiration_date).to be_nil
    end

    it "puts an increase in the undated bucket rather than on a dated batch" do
      dated = create(:inventory_item, product: product, quantity: 2, expiration_date: Date.current + 30)

      described_class.new([ entry(0, product.id, 5) ]).apply!

      expect(dated.reload.quantity).to eq(2)
      undated = product.inventory_items.where(expiration_date: nil).sole
      expect(undated.quantity).to eq(3)
    end

    it "reuses the existing undated batch rather than creating a second one" do
      undated = create(:inventory_item, product: product, quantity: 1, expiration_date: nil)

      described_class.new([ entry(0, product.id, 4) ]).apply!

      expect(product.inventory_items.count).to eq(1)
      expect(undated.reload.quantity).to eq(4)
    end

    it "deletes every batch when counted to zero, including one already at zero" do
      create(:inventory_item, product: product, quantity: 3)
      create(:inventory_item, product: product, quantity: 0, expiration_date: Date.current + 5)

      described_class.new([ entry(0, product.id, 0) ]).apply!

      expect(product.inventory_items.count).to eq(0)
      expect(product.reload.stock_verified_at).to be_present
    end

    it "sweeps a zero row the count never drained" do
      stray   = create(:inventory_item, product: product, quantity: 0, expiration_date: nil)
      stocked = create(:inventory_item, product: product, quantity: 5, expiration_date: Date.current + 2)

      described_class.new([ entry(0, product.id, 3) ]).apply!

      expect(InventoryItem.exists?(stray.id)).to be(false)
      expect(stocked.reload.quantity).to eq(3)
    end

    it "touches only the products in the request" do
      untouched = create(:product, unit_type: :weight)
      batch = create(:inventory_item, product: untouched, quantity: 9)

      described_class.new([ entry(0, product.id, 1) ]).apply!

      expect(untouched.reload.stock_verified_at).to be_nil
      expect(batch.reload.quantity).to eq(9)
    end

    it "verifies the product named by an uppercase id" do
      described_class.new([ entry(0, product.id.upcase, 2) ]).apply!

      expect(product.reload.stock_verified_at).to be_present
      expect(product.inventory_items.sole.quantity).to eq(2)
    end
  end
end
