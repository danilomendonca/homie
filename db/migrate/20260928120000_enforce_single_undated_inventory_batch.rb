class EnforceSingleUndatedInventoryBatch < ActiveRecord::Migration[8.1]
  def up
    # Merge first: the index below cannot be built while duplicates exist.
    self.class.merge_undated_batches(connection)

    add_index :inventory_items, :product_id,
      unique: true, where: "expiration_date IS NULL",
      name: "index_inventory_items_on_product_id_undated"
  end

  def down
    # The merge is not reversed: merged rows are a valid state under the old
    # schema, and the split cannot be reconstructed.
    remove_index :inventory_items, name: "index_inventory_items_on_product_id_undated"
  end

  # The oldest undated row by (created_at, id) survives — the row
  # InventoryBatchApplier and StockReconciler were already growing — and takes
  # the sum of its siblings. Zero-quantity rows are left alone; that is a data
  # policy, not something an index change should decide.
  #
  # updated_at is written Rails-side rather than as SQL now(): the column is
  # timestamp without time zone and every timestamp here is UTC written by Rails.
  def self.merge_undated_batches(connection)
    now = connection.quote(Time.current.utc)

    connection.execute <<~SQL
      WITH ranked AS (
        SELECT id,
               first_value(id) OVER w AS keeper_id,
               SUM(quantity) OVER (PARTITION BY product_id) AS total,
               COUNT(*) OVER (PARTITION BY product_id) AS n
        FROM inventory_items
        WHERE expiration_date IS NULL
        WINDOW w AS (PARTITION BY product_id ORDER BY created_at, id)
      )
      UPDATE inventory_items i
      SET quantity = r.total, updated_at = #{now}
      FROM ranked r
      WHERE i.id = r.id AND r.id = r.keeper_id AND r.n > 1
    SQL

    connection.execute <<~SQL
      DELETE FROM inventory_items i
      USING inventory_items keeper
      WHERE i.expiration_date IS NULL
        AND keeper.expiration_date IS NULL
        AND keeper.product_id = i.product_id
        AND (keeper.created_at, keeper.id) < (i.created_at, i.id)
    SQL
  end
end
