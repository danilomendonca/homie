class CreateProductAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :product_aliases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.citext :abbreviation, null: false
      t.citext :store_name
      t.references :product, type: :uuid, null: false,
        foreign_key: { on_delete: :cascade }
      t.timestamps
    end

    # NULLS NOT DISTINCT is what makes `store_name IS NULL` a single wildcard slot
    # per abbreviation. Without it Postgres treats every NULL as distinct and the
    # lookup precedence stops being deterministic.
    add_index :product_aliases, %i[abbreviation store_name],
      unique: true, nulls_not_distinct: true,
      name: "index_product_aliases_on_abbreviation_and_store_name"
  end
end
