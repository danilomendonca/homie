puts "Seeding categories…"
dairy    = Category.find_or_create_by!(name: "Dairy")
bakery   = Category.find_or_create_by!(name: "Bakery")
pantry   = Category.find_or_create_by!(name: "Pantry")
cleaning = Category.find_or_create_by!(name: "Cleaning")

puts "Seeding products…"
products = {
  milk:   Product.find_or_create_by!(name: "Milk")   { |p| p.category = dairy;    p.unit_type = "volume"; p.low_stock_threshold = 1000 },
  yogurt: Product.find_or_create_by!(name: "Yogurt") { |p| p.category = dairy;    p.unit_type = "volume"; p.low_stock_threshold = 500 },
  bread:  Product.find_or_create_by!(name: "Bread")  { |p| p.category = bakery;   p.unit_type = "unit";   p.low_stock_threshold = 2 },
  rice:   Product.find_or_create_by!(name: "Rice")   { |p| p.category = pantry;   p.unit_type = "weight"; p.low_stock_threshold = 1000 },
  flour:  Product.find_or_create_by!(name: "Flour")  { |p| p.category = pantry;   p.unit_type = "weight" },
  eggs:   Product.find_or_create_by!(name: "Eggs")   { |p| p.category = dairy;    p.unit_type = "unit";   p.low_stock_threshold = 6 },
  soap:   Product.find_or_create_by!(name: "Soap")   { |p| p.category = cleaning; p.unit_type = "unit" }
}

puts "Seeding inventory_items (mixed expiration / stock states)…"
today = Date.current

# Idempotent on (quantity, expiration_date). Saves with validate: false because the
# demo set deliberately includes an expired batch, which the on:create
# expiration_date validation would otherwise reject. Seed data is trusted.
def stock(product, quantity:, expiration_date: nil)
  scope = product.inventory_items.where(quantity: quantity, expiration_date: expiration_date)
  scope.first || scope.build.tap { |item| item.save!(validate: false) }
end

# In-stock with future expiration
stock(products[:milk],  quantity: 1000, expiration_date: today + 7)
stock(products[:milk],  quantity: 500,  expiration_date: today + 30)
stock(products[:bread], quantity: 1,    expiration_date: today + 2)   # near-expiration, low-stock

# Expired
stock(products[:yogurt], quantity: 200, expiration_date: today - 2)   # expired bucket

# Near expiration today (lower bound inclusive)
stock(products[:eggs], quantity: 6, expiration_date: today)

# Stocked, no expiration
stock(products[:rice],  quantity: 2500)
stock(products[:flour], quantity: 800)

# Fully consumed (zero-quantity batch) — visible only via include_empty=true
stock(products[:soap], quantity: 0)

puts "Seed complete: #{Category.count} categories, #{Product.count} products, #{InventoryItem.count} batches."
