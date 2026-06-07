module Api
  module V1
    class OpenapiController < BaseController
      def show
        path = Rails.root.join("swagger/openapi.json")
        unless File.exist?(path)
          raise ActionController::RoutingError,
            "openapi.json not generated — run `bundle exec rails rswag`"
        end
        send_file path, type: "application/json", disposition: "inline"
      end
    end
  end
end
