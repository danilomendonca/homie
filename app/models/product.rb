class Product < ApplicationRecord
  enum :unit_type, { unit: "unit", weight: "weight", volume: "volume" }, validate: true

  belongs_to :category, optional: true
  has_many :inventory_items, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :unit_type, presence: true
  validates :low_stock_threshold,
    numericality: { greater_than_or_equal_to: 0 },
    allow_nil: true
  validates :brand, length: { maximum: 100 }, allow_nil: true
  validates :notes, length: { maximum: 1000 }, allow_nil: true
  validate :low_stock_threshold_must_be_whole_number_when_unit
  validate :category_must_exist

  private

  def low_stock_threshold_must_be_whole_number_when_unit
    return unless unit_type == "unit"
    return if low_stock_threshold.blank?
    return if (low_stock_threshold % 1).zero?

    errors.add(:low_stock_threshold,
      "must be a whole number when unit_type is 'unit'")
  end

  def category_must_exist
    return if category_id.blank?
    return if Category.exists?(id: category_id)

    errors.add(:category_id, "must reference an existing category")
  rescue ActiveRecord::StatementInvalid
    errors.add(:category_id, "must reference an existing category")
  end
end
