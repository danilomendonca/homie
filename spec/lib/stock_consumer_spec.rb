require "rails_helper"

RSpec.describe StockConsumer do
  def entry(index, product_id, quantity)
    {
      index: index,
      raw:   { "product_id" => product_id, "quantity" => quantity },
      permitted: { product_id: product_id, quantity: quantity }
    }
  end

  let(:product) { create(:product, unit_type: :weight) }

  describe "#failures" do
    before { create(:inventory_item, product: product, quantity: 5) }

    it "is empty for a well-formed line within stock" do
      expect(described_class.new([ entry(0, product.id, 5) ]).failures).to eq([])
    end

    it "reports a blank quantity keyed to the caller's index" do
      expect(described_class.new([ entry(7, product.id, nil) ]).failures).to eq([
        { index: 7, input: { "product_id" => product.id, "quantity" => nil },
          errors: [ { field: "quantity", message: "can't be blank" } ] }
      ])
    end

    it "rejects zero: consuming nothing is a malformed line" do
      expect(described_class.new([ entry(0, product.id, 0) ]).failures.first[:errors])
        .to eq([ { field: "quantity", message: "must be greater than 0" } ])
    end

    it "rejects a quantity past InventoryItem::MAX_QUANTITY" do
      expect(described_class.new([ entry(0, product.id, "1000000000") ]).failures.first[:errors])
        .to eq([ { field: "quantity", message: "must be less than or equal to 999999999.999" } ])
    end

    it "reports an unknown product and skips the over-consumption check for it" do
      expect(described_class.new([ entry(0, SecureRandom.uuid, 1) ]).failures.first[:errors])
        .to eq([ { field: "product_id", message: "must reference an existing product" } ])
    end

    it "resolves an uppercase id" do
      expect(described_class.new([ entry(0, product.id.upcase, 1) ]).failures).to eq([])
    end

    it "compares the per-product sum against stock on hand, failing every contributing line" do
      consumer = described_class.new([ entry(0, product.id, 3), entry(1, product.id, 3) ])

      expect(consumer.failures.map { |f| f[:index] }).to eq([ 0, 1 ])
      expect(consumer.failures.first[:errors])
        .to eq([ { field: "quantity", message: "exceeds stock on hand (5.0) for this product" } ])
    end

    it "sums only lines that passed the per-line checks" do
      consumer = described_class.new([ entry(0, product.id, 4), entry(1, product.id, "abc") ])

      expect(consumer.failures.map { |f| f[:index] }).to eq([ 1 ])
    end

    it "sorts failures by index" do
      consumer = described_class.new([ entry(3, product.id, -1), entry(1, "nope", 1) ])
      expect(consumer.failures.map { |f| f[:index] }).to eq([ 1, 3 ])
    end
  end

  describe "#apply!" do
    it "drains FEFO, sweeps emptied rows and returns the remainder per product" do
      early   = create(:inventory_item, product: product, quantity: 2, expiration_date: Date.current + 1)
      undated = create(:inventory_item, product: product, quantity: 5)

      result = described_class.new([ entry(0, product.id, 3) ]).apply!

      expect(result).to eq([ { product_id: product.id, total_quantity: 4.0 } ])
      expect(InventoryItem.exists?(early.id)).to be(false)
      expect(undated.reload.quantity).to eq(4)
    end

    it "returns an empty list for no entries" do
      expect(described_class.new([]).apply!).to eq([])
    end

    it "does not touch stock_verified_at" do
      create(:inventory_item, product: product, quantity: 5)

      described_class.new([ entry(0, product.id, 1) ]).apply!

      expect(product.reload.stock_verified_at).to be_nil
    end
  end
end
