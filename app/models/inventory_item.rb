class InventoryItem < ApplicationRecord
  # The ceiling of quantity's numeric(12,3) column: 9 integer digits. Past it
  # Postgres raises ActiveRecord::RangeError, which nothing rescues and which
  # would surface as a 500 on every write path. A validation turns it into a
  # 422 naming the field, which is also what lets InventoryBatchApplier
  # #group_failures report it per index on the bulk and import paths.
  MAX_QUANTITY = BigDecimal("999999999.999")

  belongs_to :product

  validates :quantity,
    presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_QUANTITY }
  validate :quantity_must_be_whole_number_when_unit
  validate :product_must_exist
  validate :expiration_date_not_in_past, on: :create
  validate :expiration_date_must_parse
  validate :single_default_batch_per_product

  private

  def quantity_must_be_whole_number_when_unit
    return if quantity.blank?
    return unless product&.unit_type == "unit"
    return if (quantity % 1).zero?

    errors.add(:quantity,
      "must be a whole number when product unit_type is 'unit'")
  end

  def product_must_exist
    return if product_id.blank?
    return if Product.exists?(id: product_id)

    errors.add(:product_id, "must reference an existing product")
  rescue ActiveRecord::StatementInvalid
    errors.add(:product_id, "must reference an existing product")
  end

  def expiration_date_not_in_past
    return if expiration_date.blank?
    return if expiration_date >= Date.current

    errors.add(:expiration_date, "must not be in the past")
  end

  # The date cast turns garbage into nil, and nil now means "the default batch",
  # so an unparseable value must fail rather than silently become undated.
  def expiration_date_must_parse
    return unless expiration_date_unparseable?

    errors.add(:expiration_date, "is not a valid date")
  end

  # The default batch is the product's one undated row (partial unique index
  # index_inventory_items_on_product_id_undated). Write paths merge into it rather
  # than create a second; this validation is what turns the one path that can
  # still collide — a PATCH clearing expiration_date — into a field error instead
  # of a generic RecordNotUnique.
  def single_default_batch_per_product
    return unless expiration_date.nil?
    return if expiration_date_unparseable?
    return if product_id.blank?

    others = InventoryItem.where(product_id: product_id, expiration_date: nil)
    others = others.where.not(id: id) if persisted?
    return unless others.exists?

    errors.add(:expiration_date, "must be present: product already has an undated batch")
  end

  def expiration_date_unparseable?
    expiration_date.nil? && expiration_date_before_type_cast.present?
  end
end
