require "rails_helper"

RSpec.describe Category, type: :model do
  describe "validations" do
    it "is valid with a name" do
      expect(build(:category)).to be_valid
    end

    it "requires a name" do
      expect(build(:category, name: nil)).not_to be_valid
    end

    it "rejects duplicate names (case-insensitive)" do
      create(:category, name: "Dairy")
      expect(build(:category, name: "dairy")).not_to be_valid
    end
  end

  describe "associations" do
    it "nullifies products.category_id when deleted" do
      category = create(:category)
      product = create(:product, category: category)
      category.destroy
      expect(product.reload.category_id).to be_nil
    end
  end
end
