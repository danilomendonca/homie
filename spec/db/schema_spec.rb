require "rails_helper"

RSpec.describe "Database schema (PRD §10, §13 invariants)" do
  let(:conn) { ActiveRecord::Base.connection }

  it "loads the citext extension" do
    expect(conn.extensions).to include("citext")
  end

  it "loads the trigram search extensions" do
    expect(conn.extensions).to include("pg_trgm", "unaccent")
  end

  it "defines immutable_unaccent as an IMMUTABLE function" do
    result = conn.execute(<<~SQL).to_a
      SELECT provolatile
      FROM pg_proc
      JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
      WHERE proname = 'immutable_unaccent' AND nspname = 'public'
    SQL

    # A STABLE redefinition would silently break both GIN indexes below, so the
    # volatility is the assertion — not merely that the function exists.
    expect(result.map { |r| r["provolatile"] }).to eq([ "i" ])
  end

  it "has the two trigram GIN indexes on products" do
    # pg_indexes rather than conn.indexes(:products): Rails reports expression
    # indexes as opaque strings whose rendering varies by adapter version.
    defs = conn.execute(<<~SQL).to_a.map { |r| r["indexdef"] }
      SELECT indexdef FROM pg_indexes WHERE tablename = 'products'
    SQL

    # The schema qualifier is present or absent depending on search_path, so it is
    # optional in the match.
    expect(defs).to include(
      a_string_matching(/USING gin \((?:public\.)?immutable_unaccent\(\(name\)::text\) (?:public\.)?gin_trgm_ops\)/)
    )
    expect(defs).to include(
      a_string_matching(/USING gin \((?:public\.)?immutable_unaccent\(\(brand\)::text\) (?:public\.)?gin_trgm_ops\)/)
    )
  end

  it "defines the unit_type enum with the three documented values" do
    result = conn.execute(<<~SQL).to_a
      SELECT enumlabel
      FROM pg_enum
      JOIN pg_type ON pg_type.oid = pg_enum.enumtypid
      WHERE pg_type.typname = 'unit_type'
      ORDER BY enumsortorder
    SQL
    expect(result.map { |r| r["enumlabel"] }).to eq(%w[unit weight volume])
  end

  it "has the three §13 indexes on inventory_items" do
    indexes = conn.indexes(:inventory_items)
    names = indexes.map(&:name)

    expect(names).to include(
      "index_inventory_items_on_product_id",
      "index_inventory_items_on_expiration_date",
      "index_inventory_items_on_product_id_active_stock"
    )

    partial = indexes.find { |i| i.name == "index_inventory_items_on_product_id_active_stock" }
    expect(partial.where).to match(/quantity\s*>\s*\(?0\)?/)
  end

  it "enforces the citext unique indexes for case-insensitive uniqueness" do
    expect(conn.indexes(:categories).find { |i| i.columns == [ "name" ] && i.unique }).to be_present
    expect(conn.indexes(:products).find { |i| i.columns == [ "name" ] && i.unique }).to be_present

    expect(conn.columns(:categories).find { |c| c.name == "name" }.sql_type).to eq("citext")
    expect(conn.columns(:products).find { |c| c.name == "name" }.sql_type).to eq("citext")
  end
end
