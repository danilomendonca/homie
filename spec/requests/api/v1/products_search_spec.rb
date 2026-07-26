require "swagger_helper"

RSpec.describe "Api::V1::Products search", type: :request do
  path "/v1/products/search" do
    get "Fuzzy-searches products by name and brand" do
      tags "Products"
      produces "application/json"
      parameter name: :q, in: :query, type: :string, required: true
      parameter name: :min_similarity, in: :query, type: :string, required: false
      parameter name: :limit, in: :query, type: :string, required: false

      # NOTE: defining a `let` makes rswag send `<param>=<value>` (even when
      # nil → `<param>=`). Tests for an *absent* param therefore omit the let.

      response "200", "matches on brand when the name barely scores (TORRADA VISCONTI)" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "TORRADA VISCONTI" }

        before do
          create(:product, name: "Tostata Tradicional", brand: "Visconti", unit_type: :unit)
          create(:product, name: "Arroz Branco", brand: "Tio João", unit_type: :weight)
          create(:product, name: "Sabão em Pó", brand: "Omo", unit_type: :weight)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].map { |r| r["product"]["name"] }).to eq([ "Tostata Tradicional" ])

          result = body["results"].first
          expect(result["brand_similarity"]).to be >= 0.9
          expect(result["name_similarity"]).to be < 0.3
        end
      end

      response "200", "is accent-insensitive" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "pao de forma" }

        before do
          create(:product, name: "Pão de Forma Integral", unit_type: :unit)
          create(:product, name: "Detergente Líquido", unit_type: :volume)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].map { |r| r["product"]["name"] }).to eq([ "Pão de Forma Integral" ])
          expect(body["results"].first["name_similarity"]).to be >= 0.5
        end
      end

      response "200", "matches a catalogue term embedded in receipt noise" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "REFRIG COCA COLA 2L PET" }

        before do
          create(:product, name: "Refrigerante Cola 2L", brand: "Coca-Cola", unit_type: :volume)
          create(:product, name: "Sabão em Pó", brand: "Omo", unit_type: :weight)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].map { |r| r["product"]["name"] }).to eq([ "Refrigerante Cola 2L" ])
        end
      end

      response "200", "is case-insensitive without an explicit LOWER" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "torrada visconti" }

        before do
          create(:product, name: "Tostata Tradicional", brand: "Visconti", unit_type: :unit)
          create(:product, name: "Arroz Branco", brand: "Tio João", unit_type: :weight)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].map { |r| r["product"]["name"] }).to eq([ "Tostata Tradicional" ])
        end
      end

      response "200", "breaks brand ties on name_similarity when ranking variants" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "COCA COLA 2L PET" }

        before do
          create(:product, name: "Refrigerante Cola Lata 350ml", brand: "Coca-Cola", unit_type: :volume)
          create(:product, name: "Refrigerante Cola Zero 2L", brand: "Coca-Cola", unit_type: :volume)
          create(:product, name: "Refrigerante Cola 2L", brand: "Coca-Cola", unit_type: :volume)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].map { |r| r["product"]["name"] }).to eq([
            "Refrigerante Cola 2L",
            "Refrigerante Cola Zero 2L",
            "Refrigerante Cola Lata 350ml"
          ])
          expect(body["results"].map { |r| r["brand_similarity"] }.uniq).to eq([ 1.0 ])
        end
      end

      response "200", "breaks name ties with the pt-BR ICU collation" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "Marolo" }

        before do
          create(:product, name: "Alface", brand: "Marolo", unit_type: :unit)
          create(:product, name: "Água", brand: "Marolo", unit_type: :volume)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          # Codepoint order would put "Alface" (A = U+0041) before "Água" (Á = U+00C1).
          expect(body["results"].map { |r| r["product"]["name"] }).to eq([ "Água", "Alface" ])
          expect(body["results"].map { |r| r["name_similarity"] }.uniq).to eq([ 0.0 ])
        end
      end

      response "200", "returns an empty list when nothing clears the threshold" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "xyzzy" }

        before do
          create(:product, name: "Tostata Tradicional", brand: "Visconti", unit_type: :unit)
        end

        run_test! do |response|
          expect(JSON.parse(response.body)).to eq({ "results" => [] })
        end
      end

      response "200", "widens the result set with a low min_similarity" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "Cola" }
        let(:min_similarity) { "0.05" }

        before do
          create(:product, name: "Refrigerante Cola 2L", unit_type: :volume)
          create(:product, name: "Chocolate ao Leite", unit_type: :weight)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].map { |r| r["product"]["name"] })
            .to contain_exactly("Refrigerante Cola 2L", "Chocolate ao Leite")
        end
      end

      response "200", "narrows the result set with a high min_similarity" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "Cola" }
        let(:min_similarity) { "0.9" }

        before do
          create(:product, name: "Refrigerante Cola 2L", unit_type: :volume)
          create(:product, name: "Chocolate ao Leite", unit_type: :weight)
        end

        run_test! do |response|
          expect(JSON.parse(response.body)["results"]).to eq([])
        end
      end

      response "200", "caps results at limit, keeping the highest-scoring ones" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "Cola" }
        let(:min_similarity) { "0.05" }
        let(:limit) { "2" }

        before do
          create(:product, name: "Cola", unit_type: :unit)
          create(:product, name: "Cola 2L", unit_type: :volume)
          create(:product, name: "Refrigerante Cola 2L", unit_type: :volume)
          create(:product, name: "Refrigerante Cola Lata 350ml", unit_type: :volume)
          create(:product, name: "Chocolate ao Leite", unit_type: :weight)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].map { |r| r["product"]["name"] }).to eq([ "Cola", "Cola 2L" ])
        end
      end

      response "200", "defaults to min_similarity 0.3 and limit 20" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "Cola" }

        before do
          25.times { |n| create(:product, name: "Cola #{n}", unit_type: :volume) }
          create(:product, name: "Chocolate ao Leite", unit_type: :weight)
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["results"].length).to eq(20)
          # "Chocolate ao Leite" scores ~0.2 against "Cola" — below the 0.3 default.
          expect(body["results"].map { |r| r["product"]["name"] }).to all(start_with("Cola "))
        end
      end

      response "200", "wraps the full product resource alongside the three scores" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "Tostata" }

        before do
          create(:product, name: "Tostata Tradicional", brand: "Visconti",
            notes: "integral", unit_type: :unit, low_stock_threshold: 2,
            category: create(:category, name: "Padaria"))
        end

        run_test! do |response|
          result = JSON.parse(response.body)["results"].first
          expect(result.keys).to eq(%w[product similarity name_similarity brand_similarity])
          expect(result["product"].keys).to match_array(
            %w[id name brand notes category unit_type low_stock_threshold created_at updated_at]
          )
          expect(result["product"]["category"]["name"]).to eq("Padaria")
        end
      end

      response "200", "reports brand_similarity 0.0 rather than null for a product with no brand" do
        schema "$ref" => "#/components/schemas/product_search_response"
        let(:q) { "Tostata" }

        before do
          create(:product, name: "Tostata Tradicional", brand: nil, unit_type: :unit)
        end

        run_test! do |response|
          result = JSON.parse(response.body)["results"].first
          expect(result["product"]["brand"]).to be_nil
          expect(result["brand_similarity"]).to eq(0.0)
        end
      end

      response "400", "rejects an empty q" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end

      response "400", "rejects a whitespace-only q" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "   " }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end

      response "400", "rejects min_similarity 0" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "Cola" }
        let(:min_similarity) { "0" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"])
            .to match(/`min_similarity`: must be a number greater than 0 and at most 1/)
        end
      end

      response "400", "rejects min_similarity above 1" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "Cola" }
        let(:min_similarity) { "1.5" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end

      response "400", "rejects a non-numeric min_similarity" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "Cola" }
        let(:min_similarity) { "abc" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end

      response "400", "rejects limit 0" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "Cola" }
        let(:limit) { "0" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"])
            .to match(/`limit`: must be an integer between 1 and 100/)
        end
      end

      response "400", "rejects a limit above the maximum" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "Cola" }
        let(:limit) { "101" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end

      response "400", "rejects a decimal limit" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:q) { "Cola" }
        let(:limit) { "2.5" }

        run_test! do |response|
          expect(JSON.parse(response.body)["errors"]).to be_present
        end
      end
    end
  end

  # rswag insists on a `let` for a required parameter, so the truly-absent `q`
  # case cannot be expressed as a `response` block — the 400 is already
  # documented by the empty-`q` block above.
  it "rejects a missing q with the §11 error envelope" do
    get "/v1/products/search"

    expect(response).to have_http_status(:bad_request)
    body = JSON.parse(response.body)
    expect(body["errors"].first["message"]).to match(/missing or blank required query parameter `q`/)
  end
end
