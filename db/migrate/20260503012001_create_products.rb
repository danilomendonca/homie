class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.citext :name, null: false
      t.references :category, type: :uuid, foreign_key: { on_delete: :nullify }
      t.column :unit_type, :unit_type, null: false
      t.decimal :low_stock_threshold, precision: 12, scale: 3
      t.timestamps
    end

    add_index :products, :name, unique: true
    add_check_constraint :products,
      "low_stock_threshold IS NULL OR low_stock_threshold >= 0",
      name: "products_low_stock_threshold_non_negative"
  end
end
