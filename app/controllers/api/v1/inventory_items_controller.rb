module Api
  module V1
    class InventoryItemsController < BaseController
      before_action :set_item, only: %i[show update destroy]

      def index
        items = InventoryItem.all
        items = items.where(product_id: params[:product_id]) if params[:product_id].present?
        items = items.order(Arel.sql("expiration_date ASC NULLS LAST, created_at ASC"))

        render json: items.map { |i| InventoryItemSerializer.serialize(i) }
      end

      def show
        render json: InventoryItemSerializer.serialize(@item)
      end

      def create
        item = InventoryItem.create!(create_params)
        render status: :created, json: InventoryItemSerializer.serialize(item)
      end

      def update
        if params.key?(:product_id) && params[:product_id] != @item.product_id
          @item.errors.add(:product_id, "is immutable")
          raise ActiveRecord::RecordInvalid, @item
        end

        @item.update!(update_params)
        render json: InventoryItemSerializer.serialize(@item)
      end

      def destroy
        @item.destroy!
        head :no_content
      end

      private

      def set_item
        @item = InventoryItem.find(params[:id])
      end

      def create_params
        params.permit(:product_id, :quantity, :expiration_date)
      end

      def update_params
        params.permit(:quantity, :expiration_date)
      end
    end
  end
end
