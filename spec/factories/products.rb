FactoryBot.define do
  factory :product do
    sequence(:name) { |n| "Product #{n}" }
    unit_type { :unit }
    category { nil }
    low_stock_threshold { nil }
  end
end
