require "rails_helper"

RSpec.describe "catch-all 404", type: :request do
  it "returns 404 JSON envelope for undefined v1 routes" do
    get "/v1/this-route-does-not-exist"

    expect(response).to have_http_status(:not_found)
    expect(response.content_type).to include("application/json")

    body = JSON.parse(response.body)
    expect(body["errors"]).to be_an(Array)
    expect(body["errors"].first["message"]).to be_present
  end
end
