require "swagger_helper"

RSpec.describe "Api::V1::Inventory import", type: :request do
  path "/v1/inventory/import" do
    post "Imports parsed receipt lines, resolving each against the catalogue" do
      tags "Inventory"
      consumes "application/json"
      produces "application/json"
      description <<~DESC.squish
        Resolves each receipt line in order: exact (case-insensitive) product name,
        then product alias with a store-specific alias beating the wildcard, then
        trigram similarity over accent-stripped name and brand. A similarity hit is
        only taken when it is unambiguous — if more than one product clears
        auto_match_threshold, the top candidate must lead the runner-up by at least
        0.05 on name_similarity, because every product of a matching brand scores
        1.0 on the combined score. Lines that do not resolve are reported in
        `unmatched` with suggestions and are skipped; they are not errors. Set
        dry_run=true to preview the partitioning without writing (every
        inventory_item and every created product is then null, since nothing was
        persisted). create_unknown=true creates a product for an unresolved line,
        which requires unit_type on that line. NOT IDEMPOTENT: re-posting the same
        receipt adds the quantities again (PRD §15); there are no idempotency keys.
      DESC
      parameter name: :payload, in: :body,
        schema: { "$ref" => "#/components/schemas/inventory_import_request" }

      # ---------------------------------------------------------------- precedence

      response "200", "resolves an exact product name ahead of an alias for the same text" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          @exact = create(:product, name: "Leite Integral", unit_type: :volume)
          @other = create(:product, name: "Leite Desnatado", unit_type: :volume)
          create(:product_alias, abbreviation: "Leite Integral", store_name: nil, product: @other)
        end

        let(:payload) { { items: [ { name: "Leite Integral", quantity: 1 } ] } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["unmatched"]).to eq([])
          row = body["matched"].first
          expect(row["match_source"]).to eq("exact")
          expect(row["product"]["id"]).to eq(@exact.id)
          expect(row["similarity"]).to be_nil
          expect(row["name_similarity"]).to be_nil
          expect(row["brand_similarity"]).to be_nil
        end
      end

      response "200", "resolves an exact name case-insensitively (citext)" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before { @product = create(:product, name: "Leite Integral", unit_type: :volume) }

        let(:payload) { { items: [ { name: "leite integral", quantity: 1 } ] } }

        run_test! do |response|
          row = JSON.parse(response.body)["matched"].first
          expect(row["match_source"]).to eq("exact")
          expect(row["product"]["id"]).to eq(@product.id)
        end
      end

      response "200", "resolves an alias ahead of a better trigram candidate" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          # The alias target is a *poor* trigram match; "Tostata Tradicional"
          # would win on similarity. Taking the alias proves ordering, not luck.
          @aliased = create(:product, name: "Arroz Branco", brand: "Tio João", unit_type: :weight)
          create(:product, name: "Tostata Tradicional", brand: "Visconti", unit_type: :unit)
          create(:product_alias, abbreviation: "TORRADA VISCONTI", store_name: nil, product: @aliased)
        end

        let(:payload) { { items: [ { name: "TORRADA VISCONTI", quantity: 2 } ] } }

        run_test! do |response|
          row = JSON.parse(response.body)["matched"].first
          expect(row["match_source"]).to eq("alias")
          expect(row["product"]["id"]).to eq(@aliased.id)
        end
      end

      response "200", "prefers a store-specific alias over the wildcard" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          @store_product = create(:product, name: "Refrigerante Cola 2L", unit_type: :volume)
          @wildcard_product = create(:product, name: "Refrigerante Cola Zero 2L", unit_type: :volume)
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba", product: @store_product)
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: nil, product: @wildcard_product)
        end

        let(:payload) do
          { store_name: "Oba", items: [ { name: "refrig coca 2l", quantity: 1 } ] }
        end

        run_test! do |response|
          row = JSON.parse(response.body)["matched"].first
          expect(row["match_source"]).to eq("alias")
          expect(row["product"]["id"]).to eq(@store_product.id)
        end
      end

      response "200", "falls back to the wildcard alias when the store has none" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          @wildcard_product = create(:product, name: "Refrigerante Cola Zero 2L", unit_type: :volume)
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: nil, product: @wildcard_product)
        end

        let(:payload) do
          { store_name: "Carrefour", items: [ { name: "REFRIG COCA 2L", quantity: 1 } ] }
        end

        run_test! do |response|
          row = JSON.parse(response.body)["matched"].first
          expect(row["product"]["id"]).to eq(@wildcard_product.id)
        end
      end

      response "200", "ignores a store-specific alias when store_name is omitted" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          store_only = create(:product, name: "Refrigerante Cola 2L", unit_type: :volume)
          create(:product_alias, abbreviation: "REFRIG COCA 2L", store_name: "Oba", product: store_only)
        end

        let(:payload) { { items: [ { name: "REFRIG COCA 2L", quantity: 1 } ] } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["matched"]).to eq([])
          expect(body["unmatched"].first["reason"]).to eq("below_threshold")
        end
      end

      response "200", "falls back to trigram similarity on brand (TORRADA VISCONTI)" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          @product = create(:product, name: "Tostata Tradicional", brand: "Visconti", unit_type: :unit)
          create(:product, name: "Arroz Branco", brand: "Tio João", unit_type: :weight)
        end

        let(:payload) { { items: [ { name: "TORRADA VISCONTI", quantity: 3 } ] } }

        run_test! do |response|
          row = JSON.parse(response.body)["matched"].first
          expect(row["match_source"]).to eq("similarity")
          expect(row["product"]["id"]).to eq(@product.id)
          expect(row["brand_similarity"]).to be >= 0.9
          expect(row["name_similarity"]).to be < 0.3
          expect(row["inventory_item"]["quantity"]).to eq(3.0)
        end
      end

      # ------------------------------------------------------- auto-match policy

      response "200", "refuses to guess between two same-brand SKUs whose name scores tie" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          # Both names score name_similarity 0.3077 against "COCA COLA 2L", so the
          # gap is 0 and match_similarity is 1.000 for both — a coin flip, which
          # must not write inventory.
          create(:product, name: "Refrigerante Cola Zero 2L", brand: "Coca-Cola", unit_type: :volume)
          create(:product, name: "Refrigerante Cola Diet 2L", brand: "Coca-Cola", unit_type: :volume)
        end

        let(:payload) { { items: [ { name: "COCA COLA 2L", quantity: 2 } ] } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["matched"]).to eq([])
          row = body["unmatched"].first
          expect(row["reason"]).to eq("ambiguous_match")
          expect(row["suggestions"].length).to eq(2)
          expect(row["suggestions"].map { |s| s["similarity"] }.uniq).to eq([ 1.0 ])
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "200", "takes the right SKU when name_similarity is decisive (gap 0.073)" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          @correct = create(:product, name: "Refrigerante Cola 2L", brand: "Coca-Cola", unit_type: :volume)
          @zero = create(:product, name: "Refrigerante Cola Zero 2L", brand: "Coca-Cola", unit_type: :volume)
          @lata = create(:product, name: "Refrigerante Cola Lata 350ml", brand: "Coca-Cola", unit_type: :volume)
        end

        let(:payload) { { items: [ { name: "COCA COLA 2L PET", quantity: 2 } ] } }

        run_test! do |response|
          body = JSON.parse(response.body)
          row = body["matched"].first
          expect(row["match_source"]).to eq("similarity")
          expect(row["product"]["id"]).to eq(@correct.id)
          expect(row["name_similarity"]).to eq(0.381)
          expect(InventoryItem.where(product_id: [ @zero.id, @lata.id ])).to be_empty
        end
      end

      response "200", "reports a near miss as unmatched with the right product on top" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          @product = create(:product, name: "Pão de Forma Integral", unit_type: :unit)
          create(:product, name: "Detergente Líquido", unit_type: :volume)
        end

        let(:payload) { { items: [ { name: "pao de forma", quantity: 1 } ] } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["matched"]).to eq([])
          row = body["unmatched"].first
          expect(row["reason"]).to eq("below_threshold")
          # 0.591 against the 0.6 default — the dry_run + suggestions path is the
          # designed answer for a near miss, not a lower default.
          expect(row["suggestions"].first["product_id"]).to eq(@product.id)
          expect(row["suggestions"].first["similarity"]).to eq(0.591)
        end
      end

      response "200", "matches the same near miss when auto_match_threshold is lowered" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before { @product = create(:product, name: "Pão de Forma Integral", unit_type: :unit) }

        let(:payload) do
          { auto_match_threshold: 0.5, items: [ { name: "pao de forma", quantity: 1 } ] }
        end

        run_test! do |response|
          row = JSON.parse(response.body)["matched"].first
          expect(row["product"]["id"]).to eq(@product.id)
          expect(row["similarity"]).to eq(0.591)
        end
      end

      response "200", "misses the same near miss when auto_match_threshold is raised" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before { create(:product, name: "Pão de Forma Integral", unit_type: :unit) }

        let(:payload) do
          { auto_match_threshold: 0.9, items: [ { name: "pao de forma", quantity: 1 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["matched"]).to eq([])
          expect(body["unmatched"].first["reason"]).to eq("below_threshold")
        end
      end

      response "200", "caps suggestions at five and carries all three scores" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          # Seven Ype products, every name scoring 0.0 against the line: the brand
          # test alone puts all of them in play.
          [ "Agua Sanitaria", "Alcool em Gel", "Amaciante Floral", "Cera Liquida",
            "Esponja Multiuso", "Lava Loucas Gel", "Sabao em Barra" ].each do |name|
            create(:product, name: name, brand: "Ype", unit_type: :unit)
          end
        end

        let(:payload) { { items: [ { name: "PRODUTO YPE", quantity: 1 } ] } }

        run_test! do |response|
          row = JSON.parse(response.body)["unmatched"].first
          expect(row["reason"]).to eq("ambiguous_match")
          expect(row["suggestions"].length).to eq(5)
          expect(row["suggestions"].first.keys)
            .to eq(%w[product_id name similarity name_similarity brand_similarity])
          expect(row["suggestions"].map { |s| s["brand_similarity"] }.uniq).to eq([ 1.0 ])
          expect(row["suggestions"].map { |s| s["name_similarity"] }.uniq).to eq([ 0.0 ])
        end
      end

      # ------------------------------------------------------------ create_unknown

      response "200", "creates an unknown product and applies its inventory" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        let(:category) { create(:category, name: "Mercearia") }
        let(:payload) do
          {
            create_unknown: true,
            items: [
              { name: "Farinha de Mandioca", quantity: 1.5, brand: "Yoki",
                unit_type: "weight", category_id: category.id }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["matched"]).to eq([])
          expect(body["unmatched"]).to eq([])
          row = body["created"].first
          expect(row["index"]).to eq(0)
          expect(row["product"]["name"]).to eq("Farinha de Mandioca")
          expect(row["product"]["brand"]).to eq("Yoki")
          expect(row["product"]["unit_type"]).to eq("weight")
          expect(row["product"]["category"]["name"]).to eq("Mercearia")
          expect(row["inventory_item"]["quantity"]).to eq(1.5)
          expect(Product.count).to eq(1)
          expect(InventoryItem.count).to eq(1)
        end
      end

      response "200", "leaves a line unmatched when create_unknown is on but unit_type is missing" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        let(:payload) do
          { create_unknown: true, items: [ { name: "Farinha de Mandioca", quantity: 1 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"]).to eq([])
          expect(body["unmatched"].first["reason"]).to eq("missing_unit_type")
          expect(Product.count).to eq(0)
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "200", "creates one product for two lines naming the same unknown item" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        let(:payload) do
          {
            create_unknown: true,
            items: [
              { name: "Farinha de Mandioca", quantity: 1, unit_type: "weight" },
              { name: "farinha de mandioca", quantity: 2, unit_type: "weight" }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"].length).to eq(2)
          expect(body["created"].map { |r| r["product"]["id"] }.uniq.length).to eq(1)
          expect(body["created"].map { |r| r["inventory_item"]["id"] }.uniq.length).to eq(1)
          expect(Product.count).to eq(1)
          expect(InventoryItem.count).to eq(1)
          expect(InventoryItem.first.quantity).to eq(3)
        end
      end

      response "200", "does not invent a product for an ambiguous line even with create_unknown" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          create(:product, name: "Refrigerante Cola Zero 2L", brand: "Coca-Cola", unit_type: :volume)
          create(:product, name: "Refrigerante Cola Diet 2L", brand: "Coca-Cola", unit_type: :volume)
        end

        let(:payload) do
          {
            create_unknown: true,
            items: [ { name: "COCA COLA 2L", quantity: 2, unit_type: "volume" } ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"]).to eq([])
          # ambiguous_match, not missing_unit_type and not a fourth Coca-Cola SKU:
          # several products matched and the scores could not choose between them.
          expect(body["unmatched"].first["reason"]).to eq("ambiguous_match")
          expect(Product.count).to eq(2)
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "200", "reports ambiguity ahead of a missing unit_type" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          create(:product, name: "Refrigerante Cola Zero 2L", brand: "Coca-Cola", unit_type: :volume)
          create(:product, name: "Refrigerante Cola Diet 2L", brand: "Coca-Cola", unit_type: :volume)
        end

        let(:payload) do
          { create_unknown: true, items: [ { name: "COCA COLA 2L", quantity: 2 } ] }
        end

        run_test! do |response|
          row = JSON.parse(response.body)["unmatched"].first
          expect(row["reason"]).to eq("ambiguous_match")
          expect(row["suggestions"].length).to eq(2)
        end
      end

      response "200", "leaves unknowns unmatched by default" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        let(:payload) do
          { items: [ { name: "Farinha de Mandioca", quantity: 1, unit_type: "weight" } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["created"]).to eq([])
          expect(body["unmatched"].first["reason"]).to eq("below_threshold")
          expect(Product.count).to eq(0)
        end
      end

      response "422", "fails the line when a created product references an unknown category" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        let(:payload) do
          {
            create_unknown: true,
            items: [
              { name: "Farinha de Mandioca", quantity: 1, unit_type: "weight",
                category_id: SecureRandom.uuid }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].first["index"]).to eq(0)
          expect(body["failed"].first["errors"].map { |e| e["field"] }).to include("category_id")
          expect(Product.count).to eq(0)
          expect(InventoryItem.count).to eq(0)
        end
      end

      # ------------------------------------------------------ application semantics

      response "200", "merges into an existing batch with the same (product, expiration_date)" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        let(:exp) { Date.current + 5 }

        before do
          product = create(:product, name: "Leite Integral", unit_type: :volume)
          @existing = create(:inventory_item, product: product, quantity: 1000, expiration_date: exp)
        end

        let(:payload) do
          { items: [ { name: "Leite Integral", quantity: 500, expiration_date: exp.iso8601 } ] }
        end

        run_test! do |response|
          row = JSON.parse(response.body)["matched"].first
          expect(row["inventory_item"]["id"]).to eq(@existing.id)
          expect(row["inventory_item"]["quantity"]).to eq(1500.0)
          expect(InventoryItem.count).to eq(1)
        end
      end

      response "200", "sums two lines for the same product and expiration into one batch" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        let(:exp) { Date.current + 7 }

        before { create(:product, name: "Leite Integral", unit_type: :volume) }

        let(:payload) do
          {
            items: [
              { name: "Leite Integral", quantity: 500, expiration_date: exp.iso8601 },
              { name: "leite integral", quantity: 500, expiration_date: exp.iso8601 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["matched"].map { |r| r["inventory_item"]["id"] }.uniq.length).to eq(1)
          expect(InventoryItem.count).to eq(1)
          expect(InventoryItem.first.quantity).to eq(1000)
        end
      end

      response "422", "rejects a past expiration_date on a new batch" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { create(:product, name: "Leite Integral", unit_type: :volume) }

        let(:payload) do
          {
            items: [
              { name: "Leite Integral", quantity: 500, expiration_date: (Date.current - 1).iso8601 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].first["errors"].map { |e| e["field"] }).to include("expiration_date")
          expect(InventoryItem.count).to eq(0)
        end
      end

      # -------------------------------------------------------------------- dry_run

      response "200", "previews without writing anything" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before do
          @known = create(:product, name: "Leite Integral", unit_type: :volume)
          @product_count = Product.count
        end

        let(:payload) do
          {
            dry_run: true,
            create_unknown: true,
            items: [
              { name: "Leite Integral", quantity: 500 },
              { name: "Farinha de Mandioca", quantity: 1, unit_type: "weight" },
              { name: "Coisa Desconhecida", quantity: 1 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["applied"]).to be(false)
          expect(body["matched"].map { |r| r["index"] }).to eq([ 0 ])
          expect(body["created"].map { |r| r["index"] }).to eq([ 1 ])
          expect(body["unmatched"].map { |r| r["index"] }).to eq([ 2 ])
          expect(Product.count).to eq(@product_count)
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "200", "nulls every id on a dry run because nothing was persisted" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        before { create(:product, name: "Leite Integral", unit_type: :volume) }

        let(:payload) do
          {
            dry_run: true,
            create_unknown: true,
            items: [
              { name: "Leite Integral", quantity: 500 },
              { name: "Farinha de Mandioca", quantity: 1, unit_type: "weight" }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["matched"].first["inventory_item"]).to be_nil
          # The matched line still reports the product it resolved to — that one
          # already existed; only the *created* product is unreportable.
          expect(body["matched"].first["product"]).to be_present
          expect(body["created"].first["product"]).to be_nil
          expect(body["created"].first["inventory_item"]).to be_nil
        end
      end

      response "422", "still reports validation failures on a dry run, and writes nothing" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before { create(:product, name: "Leite Integral", unit_type: :volume) }

        let(:payload) do
          { dry_run: true, items: [ { name: "Leite Integral", quantity: -5 } ] }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].first["errors"].map { |e| e["field"] }).to include("quantity")
          expect(InventoryItem.count).to eq(0)
        end
      end

      # --------------------------------------------------------- rollback and params

      response "422", "rolls the whole import back when one line is invalid" do
        schema "$ref" => "#/components/schemas/inventory_item_bulk_failure_response"

        before do
          create(:product, name: "Leite Integral", unit_type: :volume)
          create(:product, name: "Arroz Branco", unit_type: :weight)
        end

        let(:payload) do
          {
            items: [
              { name: "Leite Integral", quantity: 500 },
              { name: "Arroz Branco", quantity: -1 }
            ]
          }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["failed"].length).to eq(1)
          expect(body["failed"].first["index"]).to eq(1)
          expect(body["failed"].first["input"]).to eq("name" => "Arroz Branco", "quantity" => -1)
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "200", "accepts an empty items array" do
        schema "$ref" => "#/components/schemas/inventory_import_response"

        let(:payload) { { items: [] } }

        run_test! do |response|
          expect(JSON.parse(response.body)).to eq(
            "applied" => true, "matched" => [], "created" => [], "unmatched" => []
          )
        end
      end

      response "400", "rejects a body without an items key" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { {} }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to be_present
        end
      end

      response "400", "rejects items that is not an array" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { items: "not an array" } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to be_present
        end
      end

      response "400", "rejects an items array over the limit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { items: Array.new(501) { { name: "Leite Integral", quantity: 1 } } } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"]).to match(/maximum of 500/)
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "400", "rejects a truthy-looking dry_run that is not exactly true or false" do
        schema "$ref" => "#/components/schemas/error_envelope"

        before { create(:product, name: "Leite Integral", unit_type: :volume) }

        let(:payload) { { dry_run: "maybe", items: [ { name: "Leite Integral", quantity: 1 } ] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"])
            .to match(/`dry_run`: must be true or false/)
          # The point of the strict parse: a typo must not persist a preview.
          expect(InventoryItem.count).to eq(0)
        end
      end

      response "400", "rejects a non-boolean create_unknown" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { create_unknown: "yes", items: [] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"])
            .to match(/`create_unknown`: must be true or false/)
        end
      end

      response "400", "rejects auto_match_threshold 0" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { auto_match_threshold: 0, items: [] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"].first["message"])
            .to match(/`auto_match_threshold`: must be a number greater than 0 and at most 1/)
        end
      end

      response "400", "rejects auto_match_threshold above 1" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { auto_match_threshold: 1.5, items: [] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end

      response "400", "rejects a non-numeric auto_match_threshold" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { { auto_match_threshold: "abc", items: [] } }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end
    end
  end

  # Documented non-idempotency (PRD §15): worth pinning, because the whole point
  # of the endpoint is that Danilo re-runs it every shopping trip.
  it "adds the quantities again when the same receipt is re-posted" do
    create(:product, name: "Leite Integral", unit_type: :volume)
    body = { items: [ { name: "Leite Integral", quantity: 500 } ] }

    2.times { post "/v1/inventory/import", params: body, as: :json }

    expect(response).to have_http_status(:ok)
    expect(InventoryItem.count).to eq(1)
    expect(InventoryItem.first.quantity).to eq(1000)
  end

  # The intended resolution loop for an unmatched line, end to end.
  it "resolves a previously-unmatched line once an alias is created for it" do
    product = create(:product, name: "Refrigerante Cola 2L", unit_type: :volume)
    body = { items: [ { name: "RFG CL 2L", quantity: 1 } ] }

    post "/v1/inventory/import", params: body.merge(dry_run: true), as: :json
    expect(JSON.parse(response.body)["unmatched"].length).to eq(1)

    post "/v1/product_aliases", params: { abbreviation: "RFG CL 2L", product_id: product.id }, as: :json
    expect(response).to have_http_status(:created)

    post "/v1/inventory/import", params: body, as: :json
    matched = JSON.parse(response.body)["matched"]
    expect(matched.length).to eq(1)
    expect(matched.first["match_source"]).to eq("alias")
    expect(matched.first["product"]["id"]).to eq(product.id)
  end
end
