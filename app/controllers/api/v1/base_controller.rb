module Api
  module V1
    class BaseController < ApplicationController
      include ErrorHandling

      def not_found
        render_not_found
      end
    end
  end
end
