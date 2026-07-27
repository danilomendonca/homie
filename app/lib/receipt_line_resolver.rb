# Resolves receipt line text to catalogue products for POST /v1/inventory/import,
# chaining the three primitives the previous phases shipped: exact citext name
# (Phase 3) → alias, store-specific beating wildcard (Phase 9) → trigram
# similarity over accent-stripped name and brand (Phase 8).
#
# Constructed once per request with every line name, so the two deterministic
# steps cost two queries regardless of receipt length; only the still-unresolved
# lines each cost a trigram query. At catalogue scale that is a seq scan over a
# trivial table (Phase 8 deliberately deferred index use). If a large catalogue
# ever makes it hurt, the escape hatch is a single LATERAL join over a VALUES
# list of the line names — do not build it before the numbers ask for it.
class ReceiptLineResolver
  # Phase 8's search default. Suggestions are floored here rather than at the
  # auto-match threshold so a near miss still comes back with the right product
  # on top — that is the whole point of the dry_run → alias loop.
  SUGGESTION_MIN_SIMILARITY = 0.3
  MAX_SUGGESTIONS = 5

  # Minimum name_similarity lead the top candidate needs over the runner-up when
  # more than one product clears the threshold. See #resolve_by_similarity.
  AMBIGUITY_MARGIN = 0.05

  Result = Struct.new(
    :product, :match_source, :similarity, :name_similarity, :brand_similarity,
    :reason, :suggestions,
    keyword_init: true
  )

  def initialize(names:, store_name:, threshold:)
    @store_name = store_name
    @threshold = threshold

    keys = names.map { |name| normalize(name) }.reject(&:empty?).uniq
    @exact = load_exact(keys)
    @aliases = load_aliases(keys)
  end

  def resolve(name)
    key = normalize(name)

    if (product = @exact[key])
      return Result.new(product: product, match_source: "exact", suggestions: [])
    end

    if (record = @aliases[key])
      return Result.new(product: record.product, match_source: "alias", suggestions: [])
    end

    return Result.new(reason: "below_threshold", suggestions: []) if key.empty?

    resolve_by_similarity(name.to_s.strip)
  end

  private

  # citext equality happens in Postgres, not in Ruby, so the Ruby-side hashes are
  # keyed on the downcased text — index_by(&:name) alone would miss "leite" vs
  # "Leite".
  def normalize(name)
    name.to_s.strip.downcase
  end

  def load_exact(keys)
    return {} if keys.empty?

    Product.includes(:category).where(name: keys).index_by { |p| p.name.downcase }
  end

  def load_aliases(keys)
    return {} if keys.empty?

    ProductAlias.includes(product: :category)
      .where(abbreviation: keys)
      .where(store_name: [ @store_name, nil ].uniq)
      # Postgres sorts false before true, so the store-specific row comes first
      # and ||= keeps it — the Phase 9 lookup precedence in one query instead of N.
      .order(Arel.sql("store_name IS NULL ASC"))
      .each_with_object({}) { |record, map| map[record.abbreviation.downcase] ||= record }
  end

  # One query serves both the auto-match decision and the suggestion list.
  #
  # match_similarity >= threshold is not a confidence signal, it is a brand test:
  # strict_word_similarity('Coca-Cola', 'COCA COLA 2L PET') is 1.0, so every SKU
  # of a matching brand scores exactly 1.000 and no threshold separates them.
  # name_similarity is the discriminating signal, so the tie is broken on it —
  # but only when that score is actually decisive. Otherwise this is a coin flip
  # between SKUs of one brand, and a coin flip must not write inventory.
  #
  # A brand-only hit with a garbage name score is still the right answer when it
  # is unique ("TORRADA VISCONTI" → "Tostata Tradicional" scores 0.125 on name),
  # so a name-score floor cannot be the rule — it would reject exactly the cases
  # Phase 8 exists to catch.
  def resolve_by_similarity(name)
    floor = [ SUGGESTION_MIN_SIMILARITY, @threshold ].min
    candidates = Product.fuzzy_search(name, min_similarity: floor, limit: MAX_SUGGESTIONS).to_a
    above = candidates.select { |p| p.match_similarity.to_f >= @threshold }

    case above.size
    when 0
      Result.new(reason: "below_threshold", suggestions: candidates)
    when 1
      matched(above.first)
    else
      gap = above[0].name_similarity.to_f - above[1].name_similarity.to_f
      gap >= AMBIGUITY_MARGIN ? matched(above.first) : Result.new(reason: "ambiguous_match", suggestions: above)
    end
  end

  def matched(product)
    Result.new(
      product:          product,
      match_source:     "similarity",
      similarity:       product.match_similarity.to_f,
      name_similarity:  product.name_similarity.to_f,
      brand_similarity: product.brand_similarity.to_f,
      suggestions:      []
    )
  end
end
