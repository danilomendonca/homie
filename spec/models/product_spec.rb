require "rails_helper"

RSpec.describe Product, type: :model do
  describe "validations" do
    it "is valid with required attributes" do
      expect(build(:product)).to be_valid
    end

    it "requires a name" do
      expect(build(:product, name: nil)).not_to be_valid
    end

    it "rejects duplicate names (case-insensitive)" do
      create(:product, name: "Milk")
      expect(build(:product, name: "milk")).not_to be_valid
    end

    it "requires a unit_type" do
      expect(build(:product, unit_type: nil)).not_to be_valid
    end

    it "accepts valid unit_type values" do
      %i[unit weight volume].each do |type|
        expect(build(:product, unit_type: type)).to be_valid
      end
    end

    it "allows nil low_stock_threshold" do
      expect(build(:product, low_stock_threshold: nil)).to be_valid
    end

    it "requires low_stock_threshold to be non-negative" do
      expect(build(:product, low_stock_threshold: -1)).not_to be_valid
    end

    it "accepts zero low_stock_threshold" do
      expect(build(:product, low_stock_threshold: 0)).to be_valid
    end
  end

  describe "associations" do
    it "destroys inventory_items when deleted" do
      product = create(:product)
      create(:inventory_item, product: product)
      expect { product.destroy }.to change(InventoryItem, :count).by(-1)
    end
  end
end
