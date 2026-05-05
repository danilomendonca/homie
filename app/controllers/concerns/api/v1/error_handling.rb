module Api
  module V1
    module ErrorHandling
      extend ActiveSupport::Concern

      included do
        rescue_from ActiveRecord::RecordNotFound,       with: :render_not_found
        rescue_from ActiveRecord::RecordInvalid,        with: :render_validation_error
        rescue_from ActiveRecord::RecordNotUnique,      with: :render_record_not_unique
        rescue_from ActiveRecord::InvalidForeignKey,    with: :render_invalid_foreign_key
        rescue_from ActionController::ParameterMissing, with: :render_bad_request
        rescue_from ActionController::BadRequest,       with: :render_bad_request
        rescue_from Api::Conflict,                      with: :render_conflict
      end

      private

      def render_not_found(exception = nil)
        message = exception.is_a?(ActiveRecord::RecordNotFound) && exception.model ?
          "#{exception.model} not found" : "Not found"
        render status: :not_found, json: { errors: [ { message: message } ] }
      end

      def render_validation_error(exception)
        errors = exception.record.errors.map do |err|
          { field: err.attribute.to_s, message: err.message }
        end
        render status: :unprocessable_entity, json: { errors: errors }
      end

      def render_record_not_unique(_exception)
        render status: :unprocessable_entity,
          json: { errors: [ { message: "Conflict on a unique field" } ] }
      end

      def render_invalid_foreign_key(_exception)
        render status: :unprocessable_entity,
          json: { errors: [ { message: "Invalid foreign key reference" } ] }
      end

      def render_bad_request(exception)
        render status: :bad_request, json: { errors: [ { message: exception.message } ] }
      end

      def render_conflict(exception)
        render status: :conflict, json: { errors: [ { message: exception.message } ] }
      end
    end
  end
end
