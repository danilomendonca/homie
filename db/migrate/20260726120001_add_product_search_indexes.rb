class AddProductSearchIndexes < ActiveRecord::Migration[8.1]
  # Stock unaccent(text) is STABLE, which Postgres refuses in an index expression.
  # Pinning the dictionary with 'public.unaccent'::regdictionary is what makes the
  # wrapper safe to declare IMMUTABLE.
  def up
    execute <<~SQL
      CREATE FUNCTION immutable_unaccent(text) RETURNS text AS $$
        SELECT public.unaccent('public.unaccent'::regdictionary, $1)
      $$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;
    SQL

    # name/brand are citext and gin_trgm_ops has no citext operator class, hence
    # the ::text casts — which must appear identically in any query hoping to use
    # these indexes.
    add_index :products, "immutable_unaccent(name::text) gin_trgm_ops",
      using: :gin, name: "index_products_on_name_trgm"
    add_index :products, "immutable_unaccent(brand::text) gin_trgm_ops",
      using: :gin, name: "index_products_on_brand_trgm"
  end

  def down
    remove_index :products, name: "index_products_on_brand_trgm"
    remove_index :products, name: "index_products_on_name_trgm"
    execute "DROP FUNCTION immutable_unaccent(text);"
  end
end
