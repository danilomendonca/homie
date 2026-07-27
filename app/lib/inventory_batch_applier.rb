# Additive batch write, extracted from InventoryItemsController#bulk_create so
# POST /v1/inventory/import applies inventory through the identical path rather
# than a second implementation of the same merge rule.
#
# Entries are [{ index:, raw:, permitted: { product_id:, quantity:, expiration_date: } }].
# `index` is the caller's index — a bulk item, or a receipt line — so failures
# come back keyed to whatever the caller is reporting on.
#
# Call order matters: #shape_failures must be consulted (and be empty) before
# #groups or #group_failures, because grouping casts quantity with BigDecimal()
# and that raises on exactly the garbage the shape pass exists to catch.
#
# PRD §15: single-writer in v1, so no row lock — two concurrent writers could
# lose updates.
class InventoryBatchApplier
  def initialize(entries)
    @entries = entries
  end

  def shape_failures
    @shape_failures ||= begin
      failures = {}
      @entries.each do |entry|
        item_errors = []
        qty = entry[:permitted][:quantity]

        if qty.nil? || (qty.respond_to?(:empty?) && qty.empty?)
          item_errors << { field: "quantity", message: "can't be blank" }
        else
          begin
            numeric = BigDecimal(qty.to_s)
            if numeric < 0
              item_errors << { field: "quantity", message: "must be greater than or equal to 0" }
            end
          rescue ArgumentError, TypeError
            item_errors << { field: "quantity", message: "is not a number" }
          end
        end

        if item_errors.any?
          failures[entry[:index]] = { index: entry[:index], input: entry[:raw], errors: item_errors }
        end
      end
      failures.values.sort_by { |f| f[:index] }
    end
  end

  # Groups by (product_id, expiration_date) and either merges into the oldest
  # matching existing batch (update-context validators) or creates a new batch
  # (create-context validators, including the past-date rule).
  def groups
    @groups ||= build_groups
  end

  def group_failures
    @group_failures ||= begin
      failures = {}
      groups.each do |group|
        record = group[:record]
        next if record.valid?

        record.errors.each do |err|
          group[:entries].each do |entry|
            bucket = failures[entry[:index]] ||= { index: entry[:index], input: entry[:raw], errors: [] }
            bucket[:errors] << { field: err.attribute.to_s, message: err.message }
          end
        end
      end
      failures.values.sort_by { |f| f[:index] }
    end
  end

  def apply!
    created_ids = []
    updated_ids = []
    InventoryItem.transaction do
      groups.each do |group|
        group[:record].save!
        (group[:was_new] ? created_ids : updated_ids) << group[:record].id
      end
    end
    [ created_ids, updated_ids ]
  end

  # Which batch an entry landed in. The groups already carry their entries, so
  # this is a lookup, not a second pass of the grouping rule.
  def record_for(index)
    records_by_index[index]
  end

  private

  def records_by_index
    @records_by_index ||= groups.each_with_object({}) do |group, map|
      group[:entries].each { |entry| map[entry[:index]] = group[:record] }
    end
  end

  def build_groups
    product_ids = @entries.map { |e| e[:permitted][:product_id] }.compact.uniq
    existing_by_key = {}
    if product_ids.any?
      InventoryItem.includes(:product)
        .where(product_id: product_ids)
        .order(:created_at, :id)
        .each do |item|
          key = [ item.product_id, item.expiration_date ]
          existing_by_key[key] ||= item
        end
    end

    groups_by_key = {}
    @entries.each do |entry|
      permitted = entry[:permitted]
      key = [ permitted[:product_id], normalize_date(permitted[:expiration_date]) ]
      delta = BigDecimal(permitted[:quantity].to_s)
      group = groups_by_key[key] ||= { key: key, entries: [], total_delta: BigDecimal("0") }
      group[:entries] << entry
      group[:total_delta] += delta
    end

    groups_by_key.values.map do |group|
      existing = existing_by_key[group[:key]]
      if existing
        existing.quantity = existing.quantity + group[:total_delta]
        group[:record] = existing
        group[:was_new] = false
      else
        product_id, exp_date = group[:key]
        group[:record] = InventoryItem.new(
          product_id: product_id,
          expiration_date: exp_date,
          quantity: group[:total_delta]
        )
        group[:was_new] = true
      end
      group
    end
  end

  def normalize_date(value)
    return nil if value.nil?
    return nil if value.respond_to?(:empty?) && value.empty?
    return value if value.is_a?(Date)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
