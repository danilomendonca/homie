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

    describe "whole-number quantity when product unit_type is 'unit'" do
      let(:unit_product) { create(:product, unit_type: :unit) }

      it "rejects fractional quantity" do
        item = build(:inventory_item, product: unit_product, quantity: 1.5)
        expect(item).not_to be_valid
        expect(item.errors[:quantity]).to be_present
      end

      it "accepts integer quantity" do
        expect(build(:inventory_item, product: unit_product, quantity: 2)).to be_valid
      end

      it "accepts decimals that are mathematically whole" do
        expect(build(:inventory_item, product: unit_product, quantity: 2.000)).to be_valid
      end

      it "accepts zero" do
        expect(build(:inventory_item, product: unit_product, quantity: 0)).to be_valid
      end

      it "allows fractional quantity for unit_type=weight" do
        product = create(:product, unit_type: :weight)
        expect(build(:inventory_item, product: product, quantity: 1.5)).to be_valid
      end

      it "allows fractional quantity for unit_type=volume" do
        product = create(:product, unit_type: :volume)
        expect(build(:inventory_item, product: product, quantity: 0.001)).to be_valid
      end

      it "early-returns when product is missing (existence validator owns the error)" do
        item = build(:inventory_item, product: nil, product_id: SecureRandom.uuid, quantity: 1.5)
        item.valid?
        expect(item.errors[:product_id]).to be_present
        expect(item.errors[:quantity]).to be_empty
      end
    end

    describe "product_must_exist" do
      it "is invalid with a random nonexistent UUID" do
        item = build(:inventory_item, product: nil, product_id: SecureRandom.uuid)
        expect(item).not_to be_valid
        expect(item.errors[:product_id]).to be_present
      end

      it "is valid with an existing product" do
        product = create(:product)
        expect(build(:inventory_item, product: nil, product_id: product.id)).to be_valid
      end

      it "is invalid with a malformed UUID" do
        item = build(:inventory_item, product: nil, product_id: "not-a-uuid")
        expect(item).not_to be_valid
        fields = item.errors.map(&:attribute)
        expect(fields & %i[product product_id]).not_to be_empty
      end
    end

    describe "expiration_date_not_in_past (on: :create)" do
      it "accepts today as the boundary" do
        expect(build(:inventory_item, expiration_date: Date.current)).to be_valid
      end

      it "rejects yesterday on a new record" do
        item = build(:inventory_item, expiration_date: Date.current - 1)
        expect(item).not_to be_valid
        expect(item.errors[:expiration_date]).to be_present
      end

      it "accepts a future date" do
        expect(build(:inventory_item, expiration_date: Date.current + 30)).to be_valid
      end

      it "accepts nil expiration_date" do
        expect(build(:inventory_item, expiration_date: nil)).to be_valid
      end

      it "allows updating to a past expiration_date (rule fires on create only)" do
        item = create(:inventory_item, expiration_date: Date.current + 5)
        expect(item.update(expiration_date: Date.current - 5)).to be(true)
      end
    end

    describe "single_default_batch_per_product" do
      let(:product) { create(:product) }

      it "rejects a second undated batch on expiration_date" do
        create(:inventory_item, product: product, expiration_date: nil)
        item = build(:inventory_item, product: product, expiration_date: nil)

        expect(item).not_to be_valid
        expect(item.errors[:expiration_date]).to eq([ "must be present: product already has an undated batch" ])
      end

      it "lets the undated batch update itself" do
        item = create(:inventory_item, product: product, expiration_date: nil)
        item.quantity = 9

        expect(item).to be_valid
      end

      it "allows a dated batch alongside the undated one" do
        create(:inventory_item, product: product, expiration_date: nil)

        expect(build(:inventory_item, product: product, expiration_date: Date.current + 3)).to be_valid
      end

      it "allows an undated batch for a different product" do
        create(:inventory_item, product: product, expiration_date: nil)

        expect(build(:inventory_item, expiration_date: nil)).to be_valid
      end
    end

    describe "expiration_date_must_parse" do
      let(:product) { create(:product) }

      it "rejects a garbage string with exactly one expiration_date error, even beside a default batch" do
        create(:inventory_item, product: product, expiration_date: nil)
        item = create(:inventory_item, product: product, expiration_date: Date.current + 3)
        item.expiration_date = "soon"

        expect(item).not_to be_valid
        expect(item.errors[:expiration_date]).to eq([ "is not a valid date" ])
      end

      it "accepts a blank string and nil" do
        expect(build(:inventory_item, product: product, expiration_date: "")).to be_valid
        expect(build(:inventory_item, product: product, expiration_date: nil)).to be_valid
      end
    end
  end
end
