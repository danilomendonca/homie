class Product < ApplicationRecord
  # Neither similarity function dominates: similarity() wins for whole-string
  # queries, strict_word_similarity() wins when the query embeds the catalogue
  # term in receipt noise ("REFRIG COCA COLA 2L PET"). GREATEST captures both
  # without inventing weights, and both are bounded [0,1].
  NAME_SCORE_SQL = <<~SQL.squish.freeze
    GREATEST(
      similarity(immutable_unaccent(products.name::text), immutable_unaccent(:q)),
      strict_word_similarity(immutable_unaccent(products.name::text), immutable_unaccent(:q))
    )
  SQL

  # COALESCE on brand only: brand is nullable and similarity(NULL, …) is NULL,
  # which GREATEST would ignore but the serializer would not. name is NOT NULL.
  BRAND_SCORE_SQL = <<~SQL.squish.freeze
    COALESCE(GREATEST(
      similarity(immutable_unaccent(products.brand::text), immutable_unaccent(:q)),
      strict_word_similarity(immutable_unaccent(products.brand::text), immutable_unaccent(:q))
    ), 0)
  SQL

  SCORE_SQL = "GREATEST(#{NAME_SCORE_SQL}, #{BRAND_SCORE_SQL})".freeze

  # match_similarity puts brand-only hits in play; name_similarity breaks the
  # ties between variants of one brand (every Coca-Cola product scores 1.0 on
  # brand); the pt-BR ICU collation is the stable final tiebreak this codebase
  # requires of any ordering by products.name.
  SEARCH_ORDER_SQL = <<~SQL.squish.freeze
    match_similarity DESC, name_similarity DESC, products.name COLLATE "pt-x-icu" ASC
  SQL

  # Same numeric(12,3) ceiling as InventoryItem::MAX_QUANTITY, for the same
  # reason: past it Postgres raises RangeError and the request 500s.
  MAX_LOW_STOCK_THRESHOLD = BigDecimal("999999999.999")

  enum :unit_type, { unit: "unit", weight: "weight", volume: "volume" }, validate: true

  belongs_to :category, optional: true
  has_many :inventory_items, dependent: :destroy
  has_many :product_aliases, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :unit_type, presence: true
  validates :low_stock_threshold,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_LOW_STOCK_THRESHOLD },
    allow_nil: true
  validates :brand, length: { maximum: 100 }, allow_nil: true
  validates :notes, length: { maximum: 1000 }, allow_nil: true
  validate :low_stock_threshold_must_be_whole_number_when_unit
  validate :category_must_exist

  # One place where "how much of this product is in stock" is expressed:
  # inventory#index, #low_stock and #sample all read it. Grouping by the primary
  # key leaves every products column functionally dependent, so callers can add
  # their own having/order over any of them without a MAX() wrapper.
  def self.with_total_quantity
    left_outer_joins(:inventory_items)
      .group("products.id")
      .select("products.*, COALESCE(SUM(inventory_items.quantity), 0) AS total_quantity")
  end

  # Trigram search over accent-stripped name and brand, returning name, brand and
  # combined scores as attributes on each row. Index usage is knowingly deferred:
  # the similarity() >= :min form cannot use the GIN indexes (only the % operator
  # can), and a seq scan is the right plan at catalogue scale. When it is not, add
  # an index-eligible pre-filter —
  #   immutable_unaccent(name::text) % immutable_unaccent(:q) OR … brand …
  # with SET LOCAL pg_trgm.similarity_threshold inside the request transaction.
  def self.fuzzy_search(query, min_similarity:, limit:)
    includes(:category)
      .select(sanitize_sql_array([
        "products.*, #{NAME_SCORE_SQL} AS name_similarity, " \
        "#{BRAND_SCORE_SQL} AS brand_similarity, #{SCORE_SQL} AS match_similarity",
        { q: query }
      ]))
      .where(sanitize_sql_array([ "#{SCORE_SQL} >= :min", { q: query, min: min_similarity } ]))
      .order(Arel.sql(SEARCH_ORDER_SQL))
      .limit(limit)
  end

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
