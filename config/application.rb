require_relative "boot"

require "rails"
%w[
  active_record/railtie
  active_job/railtie
  action_controller/railtie
  action_view/railtie
].each { |r| require r }

Bundler.require(*Rails.groups)

module Homie
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    config.api_only = true
    config.time_zone = ENV.fetch("TZ", "UTC")
    config.active_record.schema_format = :sql

    config.generators do |g|
      g.test_framework :rspec, fixtures: false
      g.factory_bot dir: "spec/factories"
    end
  end
end
