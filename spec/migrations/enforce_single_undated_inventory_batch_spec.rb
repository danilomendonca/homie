require "rails_helper"
require Rails.root.join("db/migrate/20260928120000_enforce_single_undated_inventory_batch")

# Runs #up inside the example's transaction: Postgres DDL is transactional, so
# dropping the index here to seed the pre-migration state is rolled back with
# everything else.
RSpec.describe EnforceSingleUndatedInventoryBatch do
  let(:conn) { ActiveRecord::Base.connection }
  let(:index_name) { "index_inventory_items_on_product_id_undated" }

  # Bypasses single_default_batch_per_product: the point is the state it forbids.
  def batch(product, quantity, created_at:, expiration_date: nil)
    item = InventoryItem.new(product: product, quantity: quantity, expiration_date: expiration_date)
    item.save!(validate: false)
    item.update_columns(created_at: created_at, updated_at: created_at)
    item
  end

  def totals
    InventoryItem.group(:product_id).sum(:quantity)
  end

  before { conn.remove_index :inventory_items, name: index_name }

  it "merges each product's undated batches into the oldest and rebuilds the index" do
    a = create(:product, unit_type: :weight)
    b = create(:product, unit_type: :weight)

    keeper = batch(a, 2, created_at: 3.days.ago)
    batch(a, 0, created_at: 2.days.ago)
    batch(a, 5, created_at: 1.day.ago)
    dated = batch(a, 4, created_at: 4.days.ago, expiration_date: Date.current + 5)
    only_b = batch(b, 1, created_at: 1.day.ago)
    only_b_updated_at = only_b.reload.updated_at

    before_totals = totals

    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }

    undated_a = InventoryItem.where(product: a, expiration_date: nil)
    expect(undated_a.pluck(:id)).to eq([ keeper.id ])
    expect(undated_a.sole.quantity).to eq(7)

    expect(dated.reload.quantity).to eq(4)
    expect(only_b.reload.quantity).to eq(1)
    expect(only_b.updated_at).to eq(only_b_updated_at)

    expect(totals).to eq(before_totals)
    expect(conn.index_name_exists?(:inventory_items, index_name)).to be(true)
  end

  it "breaks a created_at tie by id" do
    product = create(:product, unit_type: :weight)
    at = 1.day.ago
    first, second = [ batch(product, 1, created_at: at), batch(product, 2, created_at: at) ].sort_by(&:id)

    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }

    expect(InventoryItem.where(product: product).pluck(:id)).to eq([ first.id ])
    expect(InventoryItem.find(first.id).quantity).to eq(3)
    expect(InventoryItem.exists?(second.id)).to be(false)
  end
end
