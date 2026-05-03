class InventoryItem < ApplicationRecord
  belongs_to :product

  validates :quantity,
    presence: true,
    numericality: { greater_than_or_equal_to: 0 }
end
