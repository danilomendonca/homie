source "https://rubygems.org"

gem "rails", "~> 8.1.3"
gem "pg", "~> 1.5"
gem "puma", ">= 5.0"

gem "rswag-api", "~> 2.13"
gem "rswag-ui", "~> 2.13"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false

  gem "rspec-rails", "~> 7.1"
  gem "rswag-specs", "~> 2.13"
  gem "factory_bot_rails", "~> 6.4"
  gem "database_cleaner-active_record", "~> 2.2"
end
