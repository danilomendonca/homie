require "swagger_helper"

RSpec.describe "Api::V1::InventoryNearExpiration", type: :request do
  # The model rejects past expiration_date on :create, but items legitimately
  # become expired over time. Backdate via update_column to populate the
  # `expired` bucket without tripping the create-time validation.
  def create_expired(expiration_date:, **attrs)
    item = create(:inventory_item, expiration_date: Date.current + 1, **attrs)
    item.update_column(:expiration_date, expiration_date)
    item
  end

  path "/v1/inventory/near_expiration" do
    get "Lists inventory items that are expired or expiring within N days" do
      tags "Inventory"
      produces "application/json"
      parameter name: :days, in: :query, type: :string, required: false

      # NOTE: defining `let(:days)` makes rswag send `days=<value>` (even when
      # nil → `days=`). Tests for the *absent* param therefore omit the let.

      response "200", "excludes items with no expiration date" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"

        before do
          create(:inventory_item, expiration_date: nil)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expired"]).to eq([])
          expect(body["near_expiration"]).to eq([])
        end
      end

      response "200", "buckets an item expiring before today into expired" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"

        before do
          @item = create_expired(expiration_date: Date.current - 1)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expired"].map { |i| i["id"] }).to eq([ @item.id ])
          expect(body["near_expiration"]).to eq([])
        end
      end

      response "200", "buckets an item expiring today into near_expiration (lower bound inclusive)" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"

        before do
          @item = create(:inventory_item, expiration_date: Date.current)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expired"]).to eq([])
          expect(body["near_expiration"].map { |i| i["id"] }).to eq([ @item.id ])
        end
      end

      response "200", "buckets an item expiring on today + days into near_expiration (upper bound inclusive)" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"
        let(:days) { "5" }

        before do
          @item = create(:inventory_item, expiration_date: Date.current + 5)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["near_expiration"].map { |i| i["id"] }).to eq([ @item.id ])
        end
      end

      response "200", "excludes an item expiring on today + days + 1" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"
        let(:days) { "5" }

        before do
          create(:inventory_item, expiration_date: Date.current + 6)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["expired"]).to eq([])
          expect(body["near_expiration"]).to eq([])
        end
      end

      response "200", "defaults to days=3 when omitted" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"

        before do
          @in_window = create(:inventory_item, expiration_date: Date.current + 3)
          create(:inventory_item, expiration_date: Date.current + 4)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["near_expiration"].map { |i| i["id"] }).to eq([ @in_window.id ])
        end
      end

      response "200", "days=0 keeps only items expiring today in near_expiration; past items remain expired" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"
        let(:days) { "0" }

        before do
          @today     = create(:inventory_item, expiration_date: Date.current)
          @yesterday = create_expired(expiration_date: Date.current - 1)
          create(:inventory_item, expiration_date: Date.current + 1)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["near_expiration"].map { |i| i["id"] }).to eq([ @today.id ])
          expect(body["expired"].map { |i| i["id"] }).to eq([ @yesterday.id ])
        end
      end

      response "200", "days=365 is accepted" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"
        let(:days) { "365" }

        before do
          @item = create(:inventory_item, expiration_date: Date.current + 365)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["near_expiration"].map { |i| i["id"] }).to eq([ @item.id ])
        end
      end

      response "200", "orders each bucket by expiration_date ASC, then created_at ASC" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"
        let(:days) { "10" }

        before do
          @later  = create(:inventory_item, expiration_date: Date.current + 5)
          @same_a = create(:inventory_item, expiration_date: Date.current + 2)
          @same_b = create(:inventory_item, expiration_date: Date.current + 2)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["near_expiration"].map { |i| i["id"] }).to eq([ @same_a.id, @same_b.id, @later.id ])
        end
      end

      response "200", "response shape: top-level keys and per-item keys" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"
        let(:days) { "3" }

        before do
          create(:inventory_item, expiration_date: Date.current + 1)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.keys).to match_array(%w[expired near_expiration])
          item = body["near_expiration"].first
          expect(item.keys).to match_array(%w[id product_id product_name unit_type quantity expiration_date])
        end
      end

      response "200", "avoids N+1: query count is bounded regardless of item count" do
        schema "$ref" => "#/components/schemas/inventory_near_expiration_response"
        let(:days) { "10" }

        before do
          10.times { create(:inventory_item, expiration_date: Date.current + 1) }
        end

        run_test! do |_response|
          queries = []
          callback = lambda do |_name, _start, _finish, _id, payload|
            next if payload[:name].in?(%w[SCHEMA TRANSACTION CACHE])
            next if payload[:sql] =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i
            queries << payload[:sql]
          end

          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            get "/v1/inventory/near_expiration", params: { days: "10" }
          end

          expect(queries.size).to be <= 3
        end
      end

      response "400", "rejects a negative days value" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:days) { "-1" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to match(/non-negative integer between 0 and 365/)
        end
      end

      response "400", "rejects a non-numeric days value" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:days) { "abc" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"]).to be_present
        end
      end

      response "400", "rejects a decimal days value" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:days) { "3.5" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"]).to be_present
        end
      end

      response "400", "rejects an out-of-range days value" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:days) { "366" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"]).to be_present
        end
      end

      response "400", "rejects a present-but-blank days value" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:days) { "" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"]).to be_present
        end
      end
    end
  end
end
