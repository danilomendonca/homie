# Removes a stated quantity per product for POST /v1/inventory/consume, draining
# FEFO across its batches (FefoDrain) and deleting rows that end at zero.
#
# Entries are [{ index:, raw:, permitted: { product_id:, quantity: } }], keyed by
# the caller's index like InventoryBatchApplier and StockReconciler.
#
# A delta, not a count: duplicates of one product are summed (two consumption
# events are two facts, unlike two counts), and stock_verified_at is untouched
# (using stock does not confirm a count). Deliberately not a mode of
# StockReconciler — the per-line checks differ exactly where the two diverge
# (quantity > 0 rather than >= 0; duplicates summed rather than rejected; a
# stock-on-hand ceiling).
#
# Over-consumption is a failure, never a clamp: a mismatch is drift, and
# POST /v1/inventory/verify is the call that corrects it.
#
# Call order matters: #failures must be consulted (and be empty) before #apply!,
# which casts quantities with BigDecimal() and assumes every drain fits.
#
# PRD §15: single-writer in v1, so no row lock — two concurrent writers could
# lose updates.
class StockConsumer
  def initialize(entries)
    @entries = entries
  end

  def failures
    @failures ||= begin
      failures = {}
      valid = []

      @entries.each do |entry|
        item_errors = []
        amount = nil
        product = products_by_id[product_id_for(entry)]

        qty = entry[:permitted][:quantity]
        if qty.nil? || (qty.respond_to?(:empty?) && qty.empty?)
          item_errors << { field: "quantity", message: "can't be blank" }
        else
          begin
            amount = BigDecimal(qty.to_s)
            if amount <= 0
              item_errors << { field: "quantity", message: "must be greater than 0" }
              amount = nil
            elsif amount > InventoryItem::MAX_QUANTITY
              # By hand for the same reason as StockReconciler#failures: no
              # InventoryItem is validated here, and an over-large value would
              # otherwise reach BigDecimal arithmetic unchecked.
              item_errors << {
                field: "quantity",
                message: "must be less than or equal to #{InventoryItem::MAX_QUANTITY.to_s('F')}"
              }
              amount = nil
            end
          rescue ArgumentError, TypeError
            item_errors << { field: "quantity", message: "is not a number" }
          end
        end

        if product.nil?
          item_errors << { field: "product_id", message: "must reference an existing product" }
        end

        if product && amount && product.unit_type == "unit" && !(amount % 1).zero?
          item_errors << {
            field: "quantity",
            message: "must be a whole number when product unit_type is 'unit'"
          }
        end

        if item_errors.any?
          failures[entry[:index]] = { index: entry[:index], input: entry[:raw], errors: item_errors }
        else
          valid << [ entry, product.id, amount ]
        end
      end

      # Over-consumption runs on the per-product sum of the lines that passed the
      # checks above, so a product whose lines already failed on shape does not
      # also get an error computed from a partial sum. Reported on every line
      # naming that product, like InventoryBatchApplier#group_failures.
      requested = Hash.new(BigDecimal("0"))
      valid.each { |_, product_id, amount| requested[product_id] += amount }
      on_hand = stock_on_hand(requested.keys)

      valid.each do |entry, product_id, _|
        stock = on_hand.fetch(product_id, BigDecimal("0"))
        next if requested[product_id] <= stock

        failures[entry[:index]] = {
          index: entry[:index],
          input: entry[:raw],
          errors: [ { field: "quantity", message: "exceeds stock on hand (#{stock.to_f}) for this product" } ]
        }
      end

      failures.values.sort_by { |f| f[:index] }
    end
  end

  # Returns [{ product_id:, total_quantity: }], one per distinct product in order
  # of first appearance: the agent's next move is to say what is left, and the
  # drained batches are already in memory.
  def apply!
    totals = amounts_by_product_id
    return [] if totals.empty?

    InventoryItem.transaction do
      batches_by_product = FefoDrain.batches_by_product(totals.keys)
      totals.each { |product_id, amount| FefoDrain.drain(batches_by_product[product_id] || [], amount) }

      # Every batch of every touched product, including rows already at zero
      # before the request — the same sweep and reasoning as StockReconciler.
      emptied = batches_by_product.values.flatten.select { |batch| batch.quantity.zero? }.map(&:id)
      InventoryItem.where(id: emptied).delete_all if emptied.any?

      totals.keys.map do |product_id|
        remaining = (batches_by_product[product_id] || []).sum(BigDecimal("0"), &:quantity)
        { product_id: product_id, total_quantity: remaining.to_f }
      end
    end
  end

  private

  # Cast, never the raw string — see StockReconciler#product_id_for.
  def product_id_for(entry)
    Product.type_for_attribute(:id).cast(entry[:permitted][:product_id])
  end

  def products_by_id
    @products_by_id ||= begin
      ids = @entries.filter_map { |entry| product_id_for(entry) }.uniq
      ids.any? ? Product.where(id: ids).index_by(&:id) : {}
    end
  end

  def stock_on_hand(product_ids)
    return {} if product_ids.empty?

    InventoryItem.where(product_id: product_ids).group(:product_id).sum(:quantity)
  end

  # Insertion-ordered {product_id => summed amount}.
  def amounts_by_product_id
    @entries.each_with_object(Hash.new(BigDecimal("0"))) do |entry, map|
      map[product_id_for(entry)] += BigDecimal(entry[:permitted][:quantity].to_s)
    end
  end
end
