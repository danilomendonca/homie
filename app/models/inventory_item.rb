class InventoryItem < ApplicationRecord
  belongs_to :product

  validates :quantity,
    presence: true,
    numericality: { greater_than_or_equal_to: 0 }
  validate :quantity_must_be_whole_number_when_unit
  validate :product_must_exist
  validate :expiration_date_not_in_past, on: :create

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
end
