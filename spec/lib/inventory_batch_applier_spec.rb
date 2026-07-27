require "rails_helper"

# Coverage for the shared PORO itself, independent of either caller: the bulk
# endpoint and POST /v1/inventory/import both route their writes through it.
RSpec.describe InventoryBatchApplier do
  def entry(index, product_id, quantity, expiration_date = nil)
    {
      index: index,
      raw:   { "product_id" => product_id, "quantity" => quantity },
      permitted: {
        product_id: product_id, quantity: quantity, expiration_date: expiration_date
      }
    }
  end

  let(:product) { create(:product, unit_type: :weight) }

  describe "#shape_failures" do
    it "is empty for well-formed quantities" do
      applier = described_class.new([ entry(0, product.id, 2) ])
      expect(applier.shape_failures).to eq([])
    end

    it "reports a blank quantity keyed to the caller's index" do
      applier = described_class.new([ entry(7, product.id, nil) ])

      expect(applier.shape_failures).to eq([
        { index: 7, input: { "product_id" => product.id, "quantity" => nil },
          errors: [ { field: "quantity", message: "can't be blank" } ] }
      ])
    end

    it "reports a negative quantity" do
      applier = described_class.new([ entry(0, product.id, -1) ])

      expect(applier.shape_failures.first[:errors])
        .to eq([ { field: "quantity", message: "must be greater than or equal to 0" } ])
    end

    it "reports a non-numeric quantity rather than raising from the BigDecimal cast" do
      applier = described_class.new([ entry(0, product.id, "abc") ])

      expect(applier.shape_failures.first[:errors])
        .to eq([ { field: "quantity", message: "is not a number" } ])
    end

    it "sorts failures by index" do
      applier = described_class.new([ entry(3, product.id, -1), entry(1, product.id, nil) ])

      expect(applier.shape_failures.map { |f| f[:index] }).to eq([ 1, 3 ])
    end
  end

  describe "#groups" do
    it "collapses entries sharing (product_id, expiration_date) into one summed batch" do
      exp = Date.current + 3
      applier = described_class.new([
        entry(0, product.id, 2, exp.iso8601),
        entry(1, product.id, 3, exp.iso8601)
      ])

      expect(applier.groups.length).to eq(1)
      group = applier.groups.first
      expect(group[:record].quantity).to eq(5)
      expect(group[:was_new]).to be(true)
    end

    it "keeps distinct expiration dates in separate groups" do
      applier = described_class.new([
        entry(0, product.id, 2, (Date.current + 3).iso8601),
        entry(1, product.id, 2, (Date.current + 9).iso8601)
      ])

      expect(applier.groups.length).to eq(2)
    end

    it "treats a nil and a blank expiration_date as the same undated batch" do
      applier = described_class.new([ entry(0, product.id, 2, nil), entry(1, product.id, 3, "") ])

      expect(applier.groups.length).to eq(1)
      expect(applier.groups.first[:record].expiration_date).to be_nil
    end

    it "merges into the oldest matching existing batch instead of creating a second one" do
      exp = Date.current + 4
      older = create(:inventory_item, product: product, quantity: 1, expiration_date: exp)
      newer = create(:inventory_item, product: product, quantity: 10, expiration_date: exp)
      older.update_columns(created_at: 2.days.ago)
      newer.update_columns(created_at: 1.day.ago)

      applier = described_class.new([ entry(0, product.id, 5, exp.iso8601) ])

      group = applier.groups.first
      expect(group[:was_new]).to be(false)
      expect(group[:record].id).to eq(older.id)
      expect(group[:record].quantity).to eq(6)
    end
  end

  describe "#group_failures" do
    it "fans one record error out to every entry in the group" do
      unit_product = create(:product, unit_type: :unit)
      applier = described_class.new([ entry(0, unit_product.id, 0.25), entry(1, unit_product.id, 0.25) ])

      expect(applier.group_failures.map { |f| f[:index] }).to eq([ 0, 1 ])
      expect(applier.group_failures.first[:errors].map { |e| e[:field] }).to include("quantity")
    end

    it "reports the create-context past-date rule for a new batch" do
      applier = described_class.new([ entry(0, product.id, 1, (Date.current - 2).iso8601) ])

      expect(applier.group_failures.first[:errors].map { |e| e[:field] }).to include("expiration_date")
    end

    it "does not apply the past-date rule when merging into an existing batch" do
      past = Date.current - 5
      existing = create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 1)
      existing.update_columns(expiration_date: past)

      applier = described_class.new([ entry(0, product.id, 2, past.iso8601) ])

      expect(applier.group_failures).to eq([])
    end
  end

  describe "#apply!" do
    it "returns created and updated ids and persists the sums" do
      exp = Date.current + 6
      existing = create(:inventory_item, product: product, quantity: 1, expiration_date: exp)
      other = create(:product, unit_type: :weight)

      applier = described_class.new([
        entry(0, product.id, 2, exp.iso8601),
        entry(1, other.id, 4)
      ])
      created_ids, updated_ids = applier.apply!

      expect(updated_ids).to eq([ existing.id ])
      expect(created_ids.length).to eq(1)
      expect(existing.reload.quantity).to eq(3)
      expect(InventoryItem.find(created_ids.first).quantity).to eq(4)
    end

    it "leaves nothing behind when a later save fails" do
      other = create(:product, unit_type: :unit)
      applier = described_class.new([ entry(0, product.id, 2), entry(1, other.id, 1.5) ])

      expect { applier.apply! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(InventoryItem.count).to eq(0)
    end
  end

  describe "#record_for" do
    it "maps each caller index to the batch it landed in" do
      exp = Date.current + 2
      applier = described_class.new([
        entry(0, product.id, 2, exp.iso8601),
        entry(1, product.id, 3, exp.iso8601),
        entry(2, product.id, 1)
      ])
      applier.apply!

      expect(applier.record_for(0)).to eq(applier.record_for(1))
      expect(applier.record_for(0).quantity).to eq(5)
      expect(applier.record_for(2).quantity).to eq(1)
      expect(applier.record_for(2)).not_to eq(applier.record_for(0))
    end

    it "returns nil for an index that was never submitted" do
      applier = described_class.new([ entry(0, product.id, 1) ])

      expect(applier.record_for(99)).to be_nil
    end
  end
end
