class ProductAlias < ApplicationRecord
  belongs_to :product

  before_validation :normalize_text_fields

  validates :abbreviation, presence: true, length: { maximum: 200 },
    uniqueness: { scope: :store_name }
  validates :store_name, length: { maximum: 100 }, allow_nil: true
  validate :product_must_exist

  private

  # belongs_to's own required check reports on :product; callers key off the
  # request field, so mirror InventoryItem and surface :product_id too. A
  # malformed UUID casts to nil before it gets here and is caught by the
  # belongs_to check instead; the rescue is the same backstop InventoryItem
  # carries, so a cast that ever reaches the DB is a 422 and not a 500.
  def product_must_exist
    return if product_id.blank?
    return if Product.exists?(id: product_id)

    errors.add(:product_id, "must reference an existing product")
  rescue ActiveRecord::StatementInvalid
    errors.add(:product_id, "must reference an existing product")
  end

  # Receipt text arrives with padding, and a blank store must collapse to the NULL
  # wildcard — otherwise "" becomes a third tier the lookup precedence ignores.
  def normalize_text_fields
    self.abbreviation = abbreviation.strip if abbreviation.is_a?(String)
    self.store_name = store_name.is_a?(String) ? store_name.strip.presence : store_name
  end
end
