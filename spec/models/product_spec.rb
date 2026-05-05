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

    describe "whole-number low_stock_threshold when unit_type is 'unit'" do
      it "rejects fractional threshold" do
        product = build(:product, unit_type: :unit, low_stock_threshold: 1.5)
        expect(product).not_to be_valid
        expect(product.errors[:low_stock_threshold]).to be_present
      end

      it "accepts integer threshold" do
        expect(build(:product, unit_type: :unit, low_stock_threshold: 2)).to be_valid
      end

      it "accepts decimals that are mathematically whole" do
        expect(build(:product, unit_type: :unit, low_stock_threshold: 2.000)).to be_valid
      end

      it "accepts zero" do
        expect(build(:product, unit_type: :unit, low_stock_threshold: 0)).to be_valid
      end

      it "accepts nil" do
        expect(build(:product, unit_type: :unit, low_stock_threshold: nil)).to be_valid
      end

      it "allows fractional threshold for unit_type=weight" do
        expect(build(:product, unit_type: :weight, low_stock_threshold: 1.5)).to be_valid
      end

      it "allows fractional threshold for unit_type=volume" do
        expect(build(:product, unit_type: :volume, low_stock_threshold: 0.001)).to be_valid
      end
    end

    describe "invalid enum value for unit_type" do
      it "does not raise and surfaces as a validation error" do
        product = build(:product)
        expect { product.unit_type = "foo" }.not_to raise_error
        expect(product).not_to be_valid
        expect(product.errors[:unit_type]).to be_present
      end
    end

    describe "category_must_exist" do
      it "is valid with category_id = nil" do
        expect(build(:product, category: nil)).to be_valid
      end

      it "is invalid with a random nonexistent UUID" do
        product = build(:product, category_id: SecureRandom.uuid)
        expect(product).not_to be_valid
        expect(product.errors[:category_id]).to be_present
      end

      it "is valid with an existing category" do
        category = create(:category)
        expect(build(:product, category_id: category.id)).to be_valid
      end
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
