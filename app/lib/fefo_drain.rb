# First-expired-first-out removal of stock from a product's batches, shared by
# POST /v1/inventory/verify (a count below stock on hand) and
# POST /v1/inventory/consume (a stated delta). What got used is what was
# expiring soonest; the undated default batch drains last.
#
# Draining an already-expired batch is fine because
# InventoryItem#expiration_date_not_in_past is on: :create — and it has to be,
# or verify and consume would 422 exactly when they are most needed.
module FefoDrain
  BATCH_ORDER_SQL = "expiration_date ASC NULLS LAST, created_at ASC, id ASC".freeze

  # {product_id => [batches in FEFO order]} for the given products.
  def self.batches_by_product(product_ids)
    InventoryItem.where(product_id: product_ids).order(Arel.sql(BATCH_ORDER_SQL)).group_by(&:product_id)
  end

  # Subtracts `amount` across `batches` in order. A batch left positive is
  # saved; one drained to zero is left unsaved for the caller's zero sweep.
  # Callers guarantee amount <= batches' total.
  def self.drain(batches, amount)
    batches.each do |batch|
      break if amount <= 0

      taken = [ batch.quantity, amount ].min
      batch.quantity -= taken
      amount -= taken
      batch.save! if batch.quantity.positive?
    end
  end
end
