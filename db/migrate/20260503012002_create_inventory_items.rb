class CreateInventoryItems < ActiveRecord::Migration[8.1]
  def change
    create_table :inventory_items, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :product, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }
      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.date :expiration_date
      t.timestamps
    end

    add_index :inventory_items, :expiration_date
    add_index :inventory_items, :product_id,
      where: "quantity > 0",
      name: "index_inventory_items_on_product_id_active_stock"
    add_check_constraint :inventory_items, "quantity >= 0",
      name: "inventory_items_quantity_non_negative"
  end
end
