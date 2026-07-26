require "rails_helper"

RSpec.describe ProductAlias, type: :model do
  describe "validations" do
    it "is valid with required attributes" do
      expect(build(:product_alias)).to be_valid
    end

    it "requires an abbreviation" do
      expect(build(:product_alias, abbreviation: nil)).not_to be_valid
    end

    it "rejects a blank abbreviation" do
      expect(build(:product_alias, abbreviation: "   ")).not_to be_valid
    end

    it "requires a product" do
      alias_record = build(:product_alias, product: nil)
      expect(alias_record).not_to be_valid
      expect(alias_record.errors[:product]).to be_present
    end

    describe "product_must_exist" do
      it "is invalid with a random nonexistent UUID" do
        record = build(:product_alias, product_id: SecureRandom.uuid)
        expect(record).not_to be_valid
        expect(record.errors[:product_id]).to be_present
      end

      it "is invalid — not raising — with a malformed UUID" do
        record = build(:product_alias, product_id: "not-a-uuid")
        expect { record.valid? }.not_to raise_error
        # The uuid type casts unparseable input to nil, so this lands on the
        # belongs_to presence check rather than on :product_id.
        expect(record.errors).to be_present
        expect(record.errors.attribute_names).to include(:product)
      end

      it "is valid with an existing product" do
        expect(build(:product_alias, product_id: create(:product).id)).to be_valid
      end
    end

    describe "abbreviation length" do
      it "accepts 200 characters" do
        expect(build(:product_alias, abbreviation: "a" * 200)).to be_valid
      end

      it "rejects 201 characters" do
        record = build(:product_alias, abbreviation: "a" * 201)
        expect(record).not_to be_valid
        expect(record.errors[:abbreviation]).to be_present
      end
    end

    describe "store_name length" do
      it "accepts 100 characters" do
        expect(build(:product_alias, store_name: "a" * 100)).to be_valid
      end

      it "rejects 101 characters" do
        record = build(:product_alias, store_name: "a" * 101)
        expect(record).not_to be_valid
        expect(record.errors[:store_name]).to be_present
      end

      it "accepts nil" do
        expect(build(:product_alias, store_name: nil)).to be_valid
      end
    end

    describe "uniqueness scoped to store_name" do
      it "rejects a duplicate (abbreviation, store_name) pair" do
        create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        expect(build(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")).not_to be_valid
      end

      it "rejects a duplicate case-insensitively (citext)" do
        create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        expect(build(:product_alias, abbreviation: "refrig coca 2l", store_name: "oba")).not_to be_valid
      end

      it "rejects a second wildcard for the same abbreviation" do
        create(:product_alias, abbreviation: "DET YPE 500ML", store_name: nil)
        expect(build(:product_alias, abbreviation: "DET YPE 500ML", store_name: nil)).not_to be_valid
      end

      it "allows the same abbreviation under two different stores" do
        create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        expect(build(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Assaí")).to be_valid
      end

      it "allows a store-specific alias alongside the wildcard" do
        create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: nil)
        expect(build(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")).to be_valid
      end
    end
  end

  describe "normalization" do
    it "strips surrounding whitespace from abbreviation" do
      record = create(:product_alias, abbreviation: "  REFRIG COCA 2L  ")
      expect(record.abbreviation).to eq("REFRIG COCA 2L")
    end

    it "strips surrounding whitespace from store_name" do
      record = create(:product_alias, store_name: " Oba ")
      expect(record.store_name).to eq("Oba")
    end

    it "collapses a blank store_name to the NULL wildcard" do
      expect(create(:product_alias, store_name: "  ").store_name).to be_nil
      expect(create(:product_alias, store_name: "").store_name).to be_nil
    end
  end

  describe "database-level uniqueness backstop" do
    # Without the NULLS NOT DISTINCT clause on the index, Postgres treats every
    # NULL store_name as distinct and this insert would succeed — every
    # validation-level example above would still pass.
    it "rejects a duplicate wildcard inserted past the validations" do
      product = create(:product)
      create(:product_alias, abbreviation: "DET YPE 500ML", store_name: nil, product: product)

      expect {
        ProductAlias.insert_all!([ {
          abbreviation: "DET YPE 500ML", store_name: nil, product_id: product.id,
          created_at: Time.current, updated_at: Time.current
        } ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "rejects a case-insensitive duplicate inserted past the validations" do
      product = create(:product)
      create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba", product: product)

      expect {
        ProductAlias.insert_all!([ {
          abbreviation: "refrig coca 2l", store_name: "oba", product_id: product.id,
          created_at: Time.current, updated_at: Time.current
        } ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "associations" do
    it "is destroyed when its product is destroyed" do
      product = create(:product)
      create(:product_alias, product: product)
      expect { product.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
