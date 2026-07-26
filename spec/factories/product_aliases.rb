FactoryBot.define do
  factory :product_alias do
    sequence(:abbreviation) { |n| "ABBREV #{n}" }
    store_name { nil }
    product
  end
end
