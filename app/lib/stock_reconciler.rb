# Reconciles an absolute counted quantity per product against that product's
# batches, for POST /v1/inventory/verify.
#
# Entries are [{ index:, raw:, permitted: { product_id:, quantity: } }].
# `index` is the caller's index, so failures come back keyed to the line the
# caller is reporting on, exactly like InventoryBatchApplier.
#
# Deliberately not a mode of InventoryBatchApplier: that applies a *delta*
# grouped by (product_id, expiration_date); this applies an *absolute* total per
# product, drains FEFO and deletes emptied rows. The two share an interface, not
# logic.
#
# Call order matters: #failures must be consulted (and be empty) before #apply!,
# which casts quantities with BigDecimal() and assumes every product exists.
#
# PRD §15: single-writer in v1, so no row lock — two concurrent writers could
# lose updates.
class StockReconciler
  BATCH_ORDER_SQL = "expiration_date ASC NULLS LAST, created_at ASC, id ASC".freeze

  def initialize(entries)
    @entries = entries
  end

  def failures
    @failures ||= begin
      failures = {}
      seen = Set.new

      @entries.each do |entry|
        item_errors = []
        counted = nil
        product  = products_by_id[product_id_for(entry)]

        qty = entry[:permitted][:quantity]
        if qty.nil? || (qty.respond_to?(:empty?) && qty.empty?)
          item_errors << { field: "quantity", message: "can't be blank" }
        else
          begin
            counted = BigDecimal(qty.to_s)
            if counted < 0
              item_errors << { field: "quantity", message: "must be greater than or equal to 0" }
              counted = nil
            elsif counted > InventoryItem::MAX_QUANTITY
              # Checked here rather than inherited from the model validation: this
              # pass never instantiates an InventoryItem, so without it an
              # over-large count reaches save! and raises RangeError — a 500,
              # instead of this endpoint's per-index envelope.
              item_errors << {
                field: "quantity",
                message: "must be less than or equal to #{InventoryItem::MAX_QUANTITY.to_s('F')}"
              }
              counted = nil
            end
          rescue ArgumentError, TypeError
            item_errors << { field: "quantity", message: "is not a number" }
          end
        end

        # A malformed UUID casts to nil at the attribute layer, so it lands here
        # rather than in a separate branch — the same behavior InventoryItem
        # #product_must_exist has today. A per-index failure, never a 404: a
        # top-level 404 cannot say which of twenty lines was bad.
        if product.nil?
          item_errors << { field: "product_id", message: "must reference an existing product" }
        elsif seen.include?(product.id)
          # Second and later occurrences only, mirroring
          # ProductsController#collect_bulk_failures.
          item_errors << { field: "product_id", message: "is duplicated within verify request" }
        else
          seen << product.id
        end

        if product && counted && product.unit_type == "unit" && !(counted % 1).zero?
          item_errors << {
            field: "quantity",
            message: "must be a whole number when product unit_type is 'unit'"
          }
        end

        if item_errors.any?
          failures[entry[:index]] = { index: entry[:index], input: entry[:raw], errors: item_errors }
        end
      end

      failures.values.sort_by { |f| f[:index] }
    end
  end

  # Returns the number of products verified — every product in the request,
  # including the ones whose count was already correct.
  def apply!
    counts = counted_by_product_id
    return 0 if counts.empty?

    now = Time.current

    InventoryItem.transaction do
      batches_by_product = InventoryItem
        .where(product_id: counts.keys)
        .order(Arel.sql(BATCH_ORDER_SQL))
        .group_by(&:product_id)

      emptied = []

      counts.each do |product_id, counted|
        batches = batches_by_product[product_id] || []
        current = batches.sum(BigDecimal("0"), &:quantity)

        if counted < current
          drain(batches, current - counted)
        elsif counted > current
          increase(product_id, batches, counted - current)
        end
        # counted == current writes nothing. The timestamp still advances below —
        # that is the invariant the whole verification loop rests on.

        emptied.concat(batches.select { |batch| batch.quantity.zero? }.map(&:id))
      end

      # One sweep rather than a delete inside each branch: Phase 8's rule is that
      # no dead row survives for ?include_empty=true to report, and a row at zero
      # is equally dead whether this request drained it, counted it to zero, or
      # found it that way. delete_all, not destroy_all — no callbacks, no
      # dependents, as in InventoryItemsController#destroy_all.
      InventoryItem.where(id: emptied).delete_all if emptied.any?

      # update_all, not update!: a product carrying unrelated legacy invalid state
      # must not block a stock count, and there are no callbacks to run. One
      # shared `now` keeps the next sample's stock_verified_at ASC ordering
      # deterministic instead of dependent on row processing order, and
      # updated_at is bumped because the row really did change.
      Product.where(id: counts.keys).update_all(stock_verified_at: now, updated_at: now)
    end

    counts.size
  end

  private

  def product_id_for(entry)
    # Cast, never the raw string: Postgres compares uuids case-insensitively, so
    # an uppercase-but-valid id would match the WHERE and miss a raw-keyed map —
    # reporting a product that plainly exists as unknown, and hiding a duplicate.
    Product.type_for_attribute(:id).cast(entry[:permitted][:product_id])
  end

  def products_by_id
    @products_by_id ||= begin
      ids = @entries.filter_map { |entry| product_id_for(entry) }.uniq
      ids.any? ? Product.where(id: ids).index_by(&:id) : {}
    end
  end

  # Insertion-ordered {product_id => counted}. Duplicates are already rejected by
  # #failures, so each product appears exactly once.
  def counted_by_product_id
    @entries.each_with_object({}) do |entry, map|
      map[product_id_for(entry)] = BigDecimal(entry[:permitted][:quantity].to_s)
    end
  end

  # FEFO: what got eaten is what was expiring soonest. Undated batches drain last
  # (NULLS LAST in BATCH_ORDER_SQL).
  #
  # Draining an already-expired batch is fine because
  # InventoryItem#expiration_date_not_in_past is on: :create — and it has to be,
  # or verify would 422 exactly when it is most needed.
  def drain(batches, deficit)
    batches.each do |batch|
      break if deficit <= 0

      taken = [ batch.quantity, deficit ].min
      batch.quantity -= taken
      deficit -= taken
      # A batch drained to zero is left unsaved: the sweep deletes it.
      batch.save! if batch.quantity.positive?
    end
  end

  # An increase means an unrecorded purchase whose date is unknown, so it lands
  # in the undated bucket rather than on the latest-expiring batch — asserting a
  # date on a guess would make near_expiration report the new stock as expiring,
  # or (when the only batches are expired) as already expired.
  #
  # A product can hold more than one NULL-expiration batch, since
  # POST /v1/inventory_items creates rows unconditionally. The oldest by
  # (created_at, id) wins — the same tiebreak InventoryBatchApplier uses for the
  # same ambiguity. The others are deliberately left alone: consolidating them
  # would rewrite rows this count never asked about.
  def increase(product_id, batches, surplus)
    undated = batches.find { |batch| batch.expiration_date.nil? }

    if undated
      undated.quantity += surplus
      undated.save!
    else
      InventoryItem.create!(product_id: product_id, quantity: surplus, expiration_date: nil)
    end
  end
end
