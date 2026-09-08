class AddStockVerifiedAtToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :stock_verified_at, :datetime, precision: 6, null: true

    # NULLS FIRST is non-default for an ascending btree, so it has to be explicit
    # for the index to serve inventory#sample's "never verified first" ordering.
    add_index :products, :stock_verified_at,
      order: { stock_verified_at: "ASC NULLS FIRST" }
  end
end
