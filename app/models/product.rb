class Product < ApplicationRecord
  enum :unit_type, { unit: "unit", weight: "weight", volume: "volume" }

  belongs_to :category, optional: true
  has_many :inventory_items, dependent: :destroy

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :unit_type, presence: true
  validates :low_stock_threshold,
    numericality: { greater_than_or_equal_to: 0 },
    allow_nil: true
end
