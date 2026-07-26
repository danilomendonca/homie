module Api
  module V1
    class ProductAliasesController < BaseController
      before_action :set_alias, only: %i[show update destroy]

      def index
        aliases = ProductAlias.includes(product: :category)
        aliases = aliases.where(store_name: params[:store_name]) if params[:store_name].present?
        aliases = aliases.where(product_id: params[:product_id]) if params[:product_id].present?
        aliases = aliases.order(Arel.sql(%(abbreviation COLLATE "pt-x-icu" ASC)))

        render json: aliases.map { |a| ProductAliasSerializer.serialize(a) }
      end

      # Exact citext match with store-specific-beats-wildcard precedence. No fuzzy
      # fallback here by design — trigram matching is GET /v1/products/search, and
      # a later phase is what chains the two.
      def lookup
        abbreviation = params[:abbreviation].to_s.strip
        if abbreviation.empty?
          raise ActionController::BadRequest,
            "missing or blank required query parameter `abbreviation`"
        end

        store = params[:store_name].to_s.strip.presence

        record = ProductAlias
          .includes(product: :category)
          .where(abbreviation: abbreviation)
          .where(store_name: [ store, nil ].uniq)
          # Postgres sorts false before true, so the store-specific row wins.
          .order(Arel.sql("store_name IS NULL ASC"))
          .first!

        render json: ProductAliasSerializer.serialize(record)
      end

      def show
        render json: ProductAliasSerializer.serialize(@alias)
      end

      def create
        record = ProductAlias.create!(alias_params)
        render status: :created, json: ProductAliasSerializer.serialize(record)
      end

      def update
        @alias.update!(alias_params)
        render json: ProductAliasSerializer.serialize(@alias)
      end

      def destroy
        @alias.destroy!
        head :no_content
      end

      private

      def set_alias
        @alias = ProductAlias.includes(product: :category).find(params[:id])
      end

      def alias_params
        params.permit(:abbreviation, :store_name, :product_id)
      end
    end
  end
end
