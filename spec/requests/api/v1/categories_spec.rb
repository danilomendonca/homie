require "swagger_helper"

RSpec.describe "Api::V1::Categories", type: :request do
  path "/v1/categories" do
    get "Lists categories ordered by name ASC" do
      tags "Categories"
      produces "application/json"

      response "200", "lists categories" do
        schema type: :array, items: { "$ref" => "#/components/schemas/category" }

        before do
          create(:category, name: "Produce")
          create(:category, name: "Dairy")
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |c| c["name"] }).to eq(%w[Dairy Produce])
        end
      end
    end

    post "Creates a category" do
      tags "Categories"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: { name: { type: :string } },
        required: %w[name]
      }

      response "201", "creates a category" do
        schema "$ref" => "#/components/schemas/category"
        let(:payload) { { name: "Dairy" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["name"]).to eq("Dairy")
          expect(body["id"]).to be_present
          expect(body["created_at"]).to match(/\AZ?\d|\d{4}-\d{2}-\d{2}T/)
        end
      end

      response "422", "rejects a duplicate name (case-insensitive via citext)" do
        schema "$ref" => "#/components/schemas/error_envelope"

        before { create(:category, name: "Dairy") }
        let(:payload) { { name: "dairy" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["field"]).to eq("name")
        end
      end

      response "422", "rejects an empty body (presence violation)" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:payload) { {} }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["field"]).to eq("name")
        end
      end
    end
  end

  path "/v1/categories/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid

    get "Shows a category" do
      tags "Categories"
      produces "application/json"

      response "200", "returns the category" do
        schema "$ref" => "#/components/schemas/category"
        let(:category) { create(:category, name: "Dairy") }
        let(:id) { category.id }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["id"]).to eq(category.id)
          expect(body["name"]).to eq("Dairy")
        end
      end

      response "404", "returns 404 when not found" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end
    end

    patch "Updates a category" do
      tags "Categories"
      consumes "application/json"
      produces "application/json"
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: { name: { type: :string, nullable: true } }
      }

      response "200", "updates the name" do
        schema "$ref" => "#/components/schemas/category"
        let(:category) { create(:category, name: "Old") }
        let(:id) { category.id }
        let(:payload) { { name: "New" } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["name"]).to eq("New")
          expect(category.reload.name).to eq("New")
        end
      end

      response "422", "rejects null name (Merge Patch on non-nullable field)" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:category) { create(:category, name: "Old") }
        let(:id) { category.id }
        let(:payload) { { name: nil } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["field"]).to eq("name")
          expect(category.reload.name).to eq("Old")
        end
      end
    end

    delete "Deletes a category" do
      tags "Categories"

      response "204", "deletes the category" do
        let(:category) { create(:category) }
        let(:id) { category.id }

        run_test! do
          expect(Category.exists?(id)).to be(false)
        end
      end

      response "404", "returns 404 for unknown id" do
        schema "$ref" => "#/components/schemas/error_envelope"
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body["errors"].first["message"]).to be_present
        end
      end
    end
  end
end
