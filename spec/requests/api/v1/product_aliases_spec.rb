require "swagger_helper"

RSpec.describe "Api::V1::ProductAliases", type: :request do
  path "/v1/product_aliases" do
    get "Lists product aliases ordered by abbreviation ASC (pt-BR collation)" do
      tags "Product aliases"
      produces "application/json"
      parameter name: :store_name, in: :query, type: :string, required: false,
        description: "Exact (case-insensitive) store filter. This lists that store's own " \
                     "aliases only — it does not include the wildcard (store_name: null) " \
                     "aliases the store inherits. Use GET /v1/product_aliases/lookup for the " \
                     "precedence-aware read."
      parameter name: :product_id, in: :query, type: :string, required: false

      # NOTE: defining a `let` makes rswag send `<param>=<value>` (even when
      # nil → `<param>=`). Tests for an *absent* param therefore omit the let.

      response "200", "lists aliases ordered by abbreviation" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product_alias" }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L")
          create(:product_alias, abbreviation: "DET YPE 500ML")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |a| a["abbreviation"] }).to eq([ "DET YPE 500ML", "REFRIG COCA 2L" ])
        end
      end

      response "200", "filters by store_name case-insensitively (citext)" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product_alias" }
        let(:store_name) { "oba" }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
          create(:product_alias, abbreviation: "DET YPE 500ML", store_name: "Assaí")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |a| a["abbreviation"] }).to eq([ "REFRIG COCA 2L" ])
          expect(body.first["store_name"]).to eq("Oba")
        end
      end

      response "200", "does not return wildcard aliases when filtering by store_name" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product_alias" }
        let(:store_name) { "Oba" }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
          create(:product_alias, abbreviation: "DET YPE 500ML", store_name: nil)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          # The index filter is exact; the wildcard tier is lookup's business.
          expect(body.map { |a| a["abbreviation"] }).to eq([ "REFRIG COCA 2L" ])
        end
      end

      response "200", "filters by product_id" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product_alias" }
        let(:product) { create(:product, name: "Refrigerante Cola 2L", unit_type: :volume) }
        let(:product_id) { product.id }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", product: product)
          create(:product_alias, abbreviation: "DET YPE 500ML")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |a| a["abbreviation"] }).to eq([ "REFRIG COCA 2L" ])
          expect(body.first["product"]["id"]).to eq(product.id)
        end
      end

      response "200", "sorts abbreviations with the pt-BR ICU collation" do
        schema type: :array, items: { "$ref" => "#/components/schemas/product_alias" }

        before do
          create(:product_alias, abbreviation: "ALFACE AMERICANA")
          create(:product_alias, abbreviation: "ÁGUA MIN 500ML")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          # Codepoint order would put "ALFACE" (A = U+0041) before "ÁGUA" (Á = U+00C1).
          expect(body.map { |a| a["abbreviation"] }).to eq([ "ÁGUA MIN 500ML", "ALFACE AMERICANA" ])
        end
      end
    end

    post "Creates a product alias" do
      tags "Product aliases"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          abbreviation: { type: :string },
          store_name:   { type: :string, nullable: true },
          product_id:   { type: :string, format: :uuid }
        },
        required: %w[abbreviation product_id]
      }

      response "201", "creates a store-specific alias" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:product) do
          create(:product, name: "Refrigerante Cola 2L", brand: "Coca-Cola",
            notes: "2 litros", unit_type: :volume, low_stock_threshold: 1,
            category: create(:category, name: "Bebidas"))
        end
        let(:payload) do
          { abbreviation: "REFRIG COCA COLA 2L PET", store_name: "Oba", product_id: product.id }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["abbreviation"]).to eq("REFRIG COCA COLA 2L PET")
          expect(body["store_name"]).to eq("Oba")
          expect(body["product"].keys).to match_array(
            %w[id name brand notes category unit_type low_stock_threshold created_at updated_at]
          )
          expect(body["product"]["category"]["name"]).to eq("Bebidas")
        end
      end

      response "201", "creates a wildcard alias when store_name is omitted" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:product) { create(:product) }
        let(:payload) { { abbreviation: "DET YPE 500ML", product_id: product.id } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["store_name"]).to be_nil
        end
      end

      response "201", "normalizes a blank store_name to the wildcard tier" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:product) { create(:product) }
        let(:payload) { { abbreviation: "  DET YPE 500ML  ", store_name: "  ", product_id: product.id } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["store_name"]).to be_nil
          expect(body["abbreviation"]).to eq("DET YPE 500ML")
        end
      end

      response "201", "accepts the same abbreviation under two different stores" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:product) { create(:product) }
        let(:payload) do
          { abbreviation: "REFRIG COCA 2L", store_name: "Assaí", product_id: product.id }
        end

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["store_name"]).to eq("Assaí")
          expect(ProductAlias.where(abbreviation: "REFRIG COCA 2L").count).to eq(2)
        end
      end

      response "422", "rejects a duplicate (abbreviation, store_name) pair" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) do
          { abbreviation: "REFRIG COCA 2L", store_name: "Oba", product_id: product.id }
        end

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["field"]).to eq("abbreviation")
        end
      end

      response "422", "rejects a second wildcard for the same abbreviation" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) { { abbreviation: "DET YPE 500ML", product_id: product.id } }

        before do
          create(:product_alias, abbreviation: "DET YPE 500ML", store_name: nil)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["field"]).to eq("abbreviation")
          expect(ProductAlias.where(abbreviation: "DET YPE 500ML").count).to eq(1)
        end
      end

      response "422", "rejects a case-insensitive duplicate (citext)" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) do
          { abbreviation: "refrig coca 2l", store_name: "oba", product_id: product.id }
        end

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["field"]).to eq("abbreviation")
        end
      end

      response "422", "rejects a missing abbreviation" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product) { create(:product) }
        let(:payload) { { product_id: product.id } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["field"]).to eq("abbreviation")
        end
      end

      response "422", "rejects an unknown product_id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) do
          { abbreviation: "REFRIG COCA 2L", product_id: "00000000-0000-0000-0000-000000000000" }
        end

        run_test! do |response|
          fields = JSON.parse(response.body)["errors"].map { |e| e["field"] }
          expect(fields).to include("product_id")
        end
      end

      response "422", "rejects a malformed product_id without raising a 500" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { abbreviation: "REFRIG COCA 2L", product_id: "not-a-uuid" } }

        run_test! do |response|
          # The uuid type casts unparseable input to nil, so this surfaces as the
          # belongs_to presence failure — the point is that it is a 422, not a 500.
          fields = JSON.parse(response.body)["errors"].map { |e| e["field"] }
          expect(fields & %w[product product_id]).not_to be_empty
        end
      end
    end
  end

  path "/v1/product_aliases/lookup" do
    get "Resolves a store abbreviation to a product (store-specific beats wildcard)" do
      tags "Product aliases"
      produces "application/json"
      parameter name: :abbreviation, in: :query, type: :string, required: true
      parameter name: :store_name, in: :query, type: :string, required: false,
        description: "When given, a store-specific alias wins over the wildcard " \
                     "(store_name: null) alias for the same abbreviation. When omitted or " \
                     "blank, only the wildcard tier is considered."

      response "200", "prefers the store-specific alias over the wildcard" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:abbreviation) { "REFRIG COCA 2L" }
        let(:store_name) { "Oba" }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: nil,
            product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba",
            product: create(:product, name: "Refrigerante Cola Zero 2L", unit_type: :volume))
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["store_name"]).to eq("Oba")
          expect(body["product"]["name"]).to eq("Refrigerante Cola Zero 2L")
        end
      end

      response "200", "falls back to the wildcard when the store has no alias" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:abbreviation) { "REFRIG COCA 2L" }
        let(:store_name) { "Assaí" }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: nil,
            product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba",
            product: create(:product, name: "Refrigerante Cola Zero 2L", unit_type: :volume))
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["store_name"]).to be_nil
          expect(body["product"]["name"]).to eq("Refrigerante Cola 2L")
        end
      end

      response "200", "is case-insensitive on both parameters (citext)" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:abbreviation) { "refrig coca 2l" }
        let(:store_name) { "oba" }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba",
            product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["store_name"]).to eq("Oba")
        end
      end

      response "200", "strips surrounding whitespace from the abbreviation" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:abbreviation) { "  REFRIG COCA 2L  " }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: nil,
            product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["abbreviation"]).to eq("REFRIG COCA 2L")
        end
      end

      response "200", "treats a blank store_name as the wildcard lookup" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:abbreviation) { "REFRIG COCA 2L" }
        let(:store_name) { "  " }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: nil,
            product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["store_name"]).to be_nil
        end
      end

      response "404", "does not fall through to a store alias when no store is given" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:abbreviation) { "REFRIG COCA 2L" }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to eq("ProductAlias not found")
        end
      end

      response "404", "returns 404 when nothing matches" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:abbreviation) { "NADA AQUI" }

        before { create(:product_alias, abbreviation: "REFRIG COCA 2L") }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to eq("ProductAlias not found")
        end
      end

      response "400", "rejects a blank abbreviation" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:abbreviation) { "   " }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"])
            .to match(/missing or blank required query parameter `abbreviation`/)
        end
      end
    end
  end

  path "/v1/product_aliases/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid

    get "Shows a product alias" do
      tags "Product aliases"
      produces "application/json"

      response "200", "returns the alias" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:product_alias) { create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba") }
        let(:id) { product_alias.id }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["id"]).to eq(product_alias.id)
          expect(body["abbreviation"]).to eq("REFRIG COCA 2L")
          expect(body["product"]["id"]).to eq(product_alias.product_id)
        end
      end

      response "404", "returns 404 for unknown id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to be_present
        end
      end
    end

    patch "Updates a product alias" do
      tags "Product aliases"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          abbreviation: { type: :string, nullable: true },
          store_name:   { type: :string, nullable: true },
          product_id:   { type: :string, format: :uuid, nullable: true }
        }
      }

      response "200", "repoints the alias at another product" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:product_alias) do
          create(:product_alias, abbreviation: "REFRIG COCA 2L",
            product: create(:product, name: "Refrigerante Cola 2L", unit_type: :volume))
        end
        let(:id) { product_alias.id }
        let(:other) { create(:product, name: "Refrigerante Cola Zero 2L", unit_type: :volume) }
        let(:payload) { { product_id: other.id } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["product"]["id"]).to eq(other.id)
          expect(body["product"]["name"]).to eq("Refrigerante Cola Zero 2L")
          expect(product_alias.reload.product_id).to eq(other.id)
        end
      end

      response "200", "promotes a store alias to the wildcard tier with store_name: null" do
        schema "$ref" => "#/components/schemas/product_alias"
        let(:product_alias) { create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba") }
        let(:id) { product_alias.id }
        let(:payload) { { store_name: nil } }

        run_test! do |response|
          expect(JSON.parse(response.body)["store_name"]).to be_nil
          expect(product_alias.reload.store_name).to be_nil
        end
      end

      response "422", "rejects null abbreviation (Merge Patch on a non-nullable field)" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product_alias) { create(:product_alias, abbreviation: "REFRIG COCA 2L") }
        let(:id) { product_alias.id }
        let(:payload) { { abbreviation: nil } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["field"]).to eq("abbreviation")
          expect(product_alias.reload.abbreviation).to eq("REFRIG COCA 2L")
        end
      end

      response "422", "rejects an update into an existing (abbreviation, store_name) pair" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:product_alias) { create(:product_alias, abbreviation: "DET YPE 500ML", store_name: "Oba") }
        let(:id) { product_alias.id }
        let(:payload) { { abbreviation: "REFRIG COCA 2L" } }

        before do
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba")
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["field"]).to eq("abbreviation")
          expect(product_alias.reload.abbreviation).to eq("DET YPE 500ML")
        end
      end
    end

    delete "Deletes a product alias" do
      tags "Product aliases"

      response "204", "deletes the alias" do
        let(:product_alias) { create(:product_alias) }
        let(:id) { product_alias.id }

        run_test! do
          expect(ProductAlias.exists?(id)).to be(false)
        end
      end

      response "404", "returns 404 for unknown id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to be_present
        end
      end
    end
  end

  # rswag insists on a `let` for a required parameter, so the truly-absent
  # `abbreviation` case cannot be expressed as a `response` block — the 400 is
  # already documented by the blank-`abbreviation` block above.
  it "rejects a missing abbreviation with the §11 error envelope" do
    get "/v1/product_aliases/lookup"

    expect(response).to have_http_status(:bad_request)
    body = JSON.parse(response.body)
    expect(body["errors"].first["message"])
      .to match(/missing or blank required query parameter `abbreviation`/)
  end
end
