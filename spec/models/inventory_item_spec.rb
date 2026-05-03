require "rails_helper"

RSpec.describe InventoryItem, type: :model do
  describe "validations" do
    it "is valid with required attributes" do
      expect(build(:inventory_item)).to be_valid
    end

    it "requires a product" do
      expect(build(:inventory_item, product: nil)).not_to be_valid
    end

    it "requires a quantity" do
      expect(build(:inventory_item, quantity: nil)).not_to be_valid
    end

    it "rejects negative quantity" do
      expect(build(:inventory_item, quantity: -1)).not_to be_valid
    end

    it "accepts zero quantity" do
      expect(build(:inventory_item, quantity: 0)).to be_valid
    end
  end
end
