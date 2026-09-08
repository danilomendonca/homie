module Api
  module V1
    class InventoryController < BaseController
      IMPORT_LIMIT = 500
      VERIFY_LIMIT = 500
      DEFAULT_AUTO_MATCH_THRESHOLD = 0.6
      SAMPLE_DEFAULT_LIMIT = 20
      SAMPLE_MAX_LIMIT = 100

      def index
        include_empty = ActiveModel::Type::Boolean.new.cast(params[:include_empty]) || false

        scope = Product
          .with_total_quantity
          .order(Arel.sql(%(products.name COLLATE "pt-x-icu" ASC)))

        scope = scope.having("COALESCE(SUM(inventory_items.quantity), 0) > 0") unless include_empty

        products = scope.to_a

        batches_by_product = InventoryItem
          .where(product_id: products.map(&:id))
          .order(Arel.sql("expiration_date ASC NULLS LAST, created_at ASC"))
          .group_by(&:product_id)

        render json: products.map { |p|
          InventoryAggregateSerializer.serialize(p, batches_by_product[p.id] || [])
        }
      end

      def low_stock
        products = Product
          .with_total_quantity
          .where.not(low_stock_threshold: nil)
          .having("COALESCE(SUM(inventory_items.quantity), 0) < products.low_stock_threshold")
          .order(Arel.sql(
            "COALESCE(SUM(inventory_items.quantity), 0) / products.low_stock_threshold ASC, " \
            'products.name COLLATE "pt-x-icu" ASC'
          ))
          .to_a

        batches_by_product = InventoryItem
          .where(product_id: products.map(&:id))
          .order(Arel.sql("expiration_date ASC NULLS LAST, created_at ASC"))
          .group_by(&:product_id)

        render json: products.map { |p|
          InventoryLowStockSerializer.serialize(p, batches_by_product[p.id] || [])
        }
      end

      def near_expiration
        days = parse_days(params[:days])

        today = Date.current
        upper = today + days
        items = InventoryItem
          .includes(:product)
          .where.not(expiration_date: nil)
          .where("expiration_date <= ?", upper)
          .order(Arel.sql("inventory_items.expiration_date ASC, inventory_items.created_at ASC"))

        expired, near = items.partition { |i| i.expiration_date < today }

        render json: {
          expired: expired.map { |i| InventoryNearExpirationSerializer.serialize(i) },
          near_expiration: near.map { |i| InventoryNearExpirationSerializer.serialize(i) }
        }
      end

      # Collapses the manual-paste flow (categories → products/bulk →
      # inventory_items/bulk, plus per-line inference on the caller's side) into
      # one call that resolves receipt lines against the catalogue server-side.
      #
      # Unmatched lines are not errors: they are reported, skipped, and the
      # request still succeeds. Only validation failures produce the per-index
      # 422 `failed` envelope the other bulk endpoints use.
      #
      # Not idempotent (PRD §15): re-posting the same receipt re-adds quantities.
      def import
        raise ActionController::ParameterMissing, :items unless params[:items].is_a?(Array)

        if params[:items].size > IMPORT_LIMIT
          return render status: :bad_request,
            json: { errors: [ { message: "items array exceeds maximum of #{IMPORT_LIMIT} items" } ] }
        end

        dry_run        = parse_boolean(params[:dry_run], "dry_run")
        create_unknown = parse_boolean(params[:create_unknown], "create_unknown")
        threshold      = parse_threshold(params[:auto_match_threshold])
        store_name     = params[:store_name].to_s.strip.presence

        lines = prepare_import_lines(params[:items])
        matched, created, unmatched = partition_import_lines(lines, store_name, threshold, create_unknown)

        failed = []
        applier = nil

        # One transaction covers product creation and the batch write, so a bad
        # quantity on the last line leaves nothing behind from the earlier ones.
        # A dry run runs the identical path and rolls it back — that is what makes
        # the preview's partitioning provably the same as the real thing, and why
        # the transiently-assigned ids are deliberately not reported (see the
        # serializer).
        ActiveRecord::Base.transaction do
          failed = collect_new_product_failures(created)
          raise ActiveRecord::Rollback if failed.any?

          created.each { |entry| entry[:product].save! if entry[:product].new_record? }

          applier = InventoryBatchApplier.new(build_applier_entries(matched + created))
          failed = applier.shape_failures
          failed = applier.group_failures if failed.empty?
          raise ActiveRecord::Rollback if failed.any?

          applier.apply!
          raise ActiveRecord::Rollback if dry_run
        end

        return render status: :unprocessable_entity, json: { failed: failed } if failed.any?

        render json: InventoryImportSerializer.serialize(
          applied:   !dry_run,
          matched:   attach_batches(matched, applier),
          created:   attach_batches(created, applier),
          unmatched: unmatched
        )
      end

      # "Which products are most overdue for a count?" — the read half of the
      # verification loop, ordered least-recently-verified first.
      #
      # The candidate set is every product, including those with no batches and
      # those at zero total quantity: "did I actually run out of rice?" is exactly
      # the question a count answers, and it is unanswerable if the sample only
      # shows what is already in stock. This is the one place with_total_quantity
      # is used unfiltered.
      def sample
        products = Product
          .with_total_quantity
          .order(Arel.sql(
            'products.stock_verified_at ASC NULLS FIRST, products.name COLLATE "pt-x-icu" ASC'
          ))
          .limit(parse_sample_limit(params[:limit]))

        render json: { items: products.map { |p| InventorySampleSerializer.serialize(p) } }
      end

      # Writes one counted number back per product. POST, not PATCH: PATCH here
      # means JSON Merge Patch on a single resource (PRD §8.0), and every bulk
      # action in this API is a POST.
      #
      # A partial reply is the normal case — only the products present in the body
      # are touched, and the rest keep their old timestamp and stay at the front
      # of the next sample.
      def verify
        raise ActionController::ParameterMissing, :items unless params[:items].is_a?(Array)

        if params[:items].size > VERIFY_LIMIT
          return render status: :bad_request,
            json: { errors: [ { message: "items array exceeds maximum of #{VERIFY_LIMIT} items" } ] }
        end

        reconciler = StockReconciler.new(prepare_verify_entries(params[:items]))
        failures = reconciler.failures
        return render status: :unprocessable_entity, json: { failed: failures } if failures.any?

        render json: { verified: reconciler.apply! }
      end

      private

      # Mirrors prepare_import_lines / prepare_bulk_inputs, with one divergence: a
      # non-object element (items: ["arroz"]) becomes an empty line and so a
      # per-index 422 rather than raising on .to_h. prepare_import_lines 500s
      # there; that is a pre-existing bug on /import, not one to reproduce here.
      #
      # Its `input` echoes as {} because the shared failure schema types `input`
      # as the object the caller sent for that line, and here the caller sent
      # none. `index` is what identifies the offending line.
      def prepare_verify_entries(items)
        items.each_with_index.map do |attrs, index|
          wrapped =
            case attrs
            when ActionController::Parameters then attrs
            when Hash then ActionController::Parameters.new(attrs)
            else ActionController::Parameters.new
            end
          permitted = wrapped.permit(:product_id, :quantity)

          {
            index: index,
            raw:   wrapped.to_unsafe_h,
            permitted: { product_id: permitted[:product_id], quantity: permitted[:quantity] }
          }
        end
      end

      # A copy of ProductsController#parse_limit rather than a shared helper: the
      # only shared part is the constants, and the two endpoints' limits are free
      # to diverge.
      def parse_sample_limit(raw)
        return SAMPLE_DEFAULT_LIMIT if raw.nil?

        value = raw.to_s
        unless value.match?(/\A\d+\z/) && (1..SAMPLE_MAX_LIMIT).cover?(value.to_i)
          raise ActionController::BadRequest,
            "invalid value for query parameter `limit`: " \
            "must be an integer between 1 and #{SAMPLE_MAX_LIMIT}"
        end

        value.to_i
      end

      # to_s first: a repeated query param (?days[]=3) arrives as an Array, which
      # does not answer match? — the same normalization parse_threshold has always
      # done.
      def parse_days(raw)
        return 3 if raw.nil?

        value = raw.to_s
        unless value.match?(/\A\d+\z/) && (0..365).cover?(value.to_i)
          raise ActionController::BadRequest,
            "invalid value for query parameter `days`: must be a non-negative integer between 0 and 365"
        end

        value.to_i
      end

      # Strict, not lenient: ActiveModel::Type::Boolean.cast returns true for
      # "yes" *and* for "maybe", and the dangerous direction here is a typo'd
      # `dry_run` silently reading as false and persisting a receipt the caller
      # wanted previewed. Same reasoning as the inventory reset's `confirm` guard.
      def parse_boolean(raw, name)
        return false if raw.nil?
        return true  if raw == true  || raw == "true"
        return false if raw == false || raw == "false"

        raise ActionController::BadRequest,
          "invalid value for `#{name}`: must be true or false"
      end

      # Regex-then-range, mirroring ProductsController#parse_min_similarity:
      # to_f on garbage silently yields 0, which would auto-match everything.
      def parse_threshold(raw)
        return DEFAULT_AUTO_MATCH_THRESHOLD if raw.nil?

        value = raw.to_s
        unless value.match?(/\A\d*\.?\d+\z/) && value.to_f > 0 && value.to_f <= 1
          raise ActionController::BadRequest,
            "invalid value for `auto_match_threshold`: " \
            "must be a number greater than 0 and at most 1"
        end

        value.to_f
      end

      # low_stock_threshold and notes are deliberately not permitted per line:
      # neither is derivable from a receipt.
      def prepare_import_lines(items)
        items.each_with_index.map do |attrs, index|
          # A non-object element (items: ["arroz"]) becomes an empty line rather
          # than raising on .to_h, which used to 500. It then carries no name, so
          # it resolves to nothing and is reported in `unmatched` and skipped —
          # the same treatment a line with a blank name already gets.
          wrapped =
            case attrs
            when ActionController::Parameters then attrs
            when Hash then ActionController::Parameters.new(attrs)
            else ActionController::Parameters.new
            end
          permitted = wrapped.permit(:name, :quantity, :expiration_date, :brand, :unit_type, :category_id)
          {
            index:           index,
            input:           wrapped.to_unsafe_h,
            name:            permitted[:name],
            quantity:        permitted[:quantity],
            expiration_date: permitted[:expiration_date],
            brand:           permitted[:brand],
            unit_type:       permitted[:unit_type],
            category_id:     permitted[:category_id]
          }
        end
      end

      def partition_import_lines(lines, store_name, threshold, create_unknown)
        resolver = ReceiptLineResolver.new(
          names: lines.map { |line| line[:name] }, store_name: store_name, threshold: threshold
        )

        matched = []
        created = []
        unmatched = []
        new_products = {}

        lines.each do |line|
          result = resolver.resolve(line[:name])

          if result.product
            matched << line.merge(
              product:          result.product,
              match_source:     result.match_source,
              similarity:       result.similarity,
              name_similarity:  result.name_similarity,
              brand_similarity: result.brand_similarity
            )
          elsif !create_unknown || result.reason == "ambiguous_match"
            # create_unknown deliberately does not fire on an ambiguous line.
            # "below_threshold" means nothing in the catalogue matched, so a new
            # product is the right answer; "ambiguous_match" means several did and
            # the scores could not choose, and inventing a fourth Coca-Cola SKU
            # there is the same catalogue corruption the guard exists to prevent.
            # Such a line needs Danilo to pick, then an alias.
            unmatched << line.merge(reason: result.reason, suggestions: result.suggestions)
          elsif line[:unit_type].blank?
            # Guessing a unit type server-side would silently corrupt the
            # catalogue, and the decision rule is a human one.
            unmatched << line.merge(reason: "missing_unit_type", suggestions: result.suggestions)
          else
            # Deduplicated by downcased name: a receipt legitimately lists the
            # same item twice, and those two lines must become one product with
            # both quantities merged through the additive path rather than a
            # collision on the citext unique index. (The products/bulk endpoint
            # reports intra-request duplicates as failures; here they merge.)
            key = line[:name].to_s.strip.downcase
            product = new_products[key] ||= Product.new(
              name:        line[:name].to_s.strip,
              brand:       line[:brand],
              unit_type:   line[:unit_type],
              category_id: line[:category_id]
            )
            created << line.merge(product: product)
          end
        end

        [ matched, created, unmatched ]
      end

      # An invalid new product (unknown category_id, bad unit_type) is a per-line
      # failure on every line that named it, and rolls the whole request back.
      def collect_new_product_failures(created)
        failures = {}
        created.group_by { |entry| entry[:product] }.each do |product, entries|
          next if product.valid?

          product.errors.each do |err|
            entries.each do |entry|
              bucket = failures[entry[:index]] ||= { index: entry[:index], input: entry[:input], errors: [] }
              bucket[:errors] << { field: err.attribute.to_s, message: err.message }
            end
          end
        end
        failures.values.sort_by { |f| f[:index] }
      end

      # The applier's `index` is the receipt-line index, so its failure rows come
      # back keyed to the line the caller is reporting on.
      def build_applier_entries(entries)
        entries.sort_by { |entry| entry[:index] }.map do |entry|
          {
            index: entry[:index],
            raw:   entry[:input],
            permitted: {
              product_id:      entry[:product].id,
              quantity:        entry[:quantity],
              expiration_date: entry[:expiration_date]
            }
          }
        end
      end

      def attach_batches(entries, applier)
        entries.map { |entry| entry.merge(inventory_item: applier.record_for(entry[:index])) }
      end
    end
  end
end
