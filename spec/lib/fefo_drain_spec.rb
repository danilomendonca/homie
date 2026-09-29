require "rails_helper"

RSpec.describe FefoDrain do
  let(:product) { create(:product, unit_type: :weight) }

  describe ".batches_by_product" do
    it "orders earliest expiration first, undated last, ties by (created_at, id)" do
      undated = create(:inventory_item, product: product, quantity: 1, expiration_date: nil)
      late    = create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 9)
      tie_new = create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 2)
      tie_old = create(:inventory_item, product: product, quantity: 1, expiration_date: Date.current + 2)
      tie_old.update_column(:created_at, 1.day.ago)

      batches = described_class.batches_by_product([ product.id ])[product.id]

      expect(batches.map(&:id)).to eq([ tie_old.id, tie_new.id, late.id, undated.id ])
    end

    it "omits products with no batches" do
      expect(described_class.batches_by_product([ product.id ])).to eq({})
    end
  end

  describe ".drain" do
    it "saves a partially drained batch and leaves the later ones alone" do
      early = create(:inventory_item, product: product, quantity: 5, expiration_date: Date.current + 1)
      later = create(:inventory_item, product: product, quantity: 5, expiration_date: nil)

      described_class.drain(described_class.batches_by_product([ product.id ])[product.id], 2)

      expect(early.reload.quantity).to eq(3)
      expect(later.reload.quantity).to eq(5)
    end

    it "spills into the next batch and leaves a fully drained one unsaved at zero" do
      early = create(:inventory_item, product: product, quantity: 2, expiration_date: Date.current + 1)
      later = create(:inventory_item, product: product, quantity: 5, expiration_date: nil)
      batches = described_class.batches_by_product([ product.id ])[product.id]

      described_class.drain(batches, 3)

      expect(batches.first.quantity).to eq(0)
      expect(early.reload.quantity).to eq(2)
      expect(later.reload.quantity).to eq(4)
    end
  end
end
