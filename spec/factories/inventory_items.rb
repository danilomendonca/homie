FactoryBot.define do
  factory :inventory_item do
    product
    quantity { 1.0 }
    expiration_date { nil }
  end
end
