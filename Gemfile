source "https://rubygems.org"

# Ruby version requirement is declared in standard_id.gemspec
# (required_ruby_version) so the CI matrix can exercise all
# supported 4.x patch versions without bundler frozen-mode rejecting
# anything other than the local .ruby-version pin.

# Specify your gem's dependencies in standard_id.gemspec.
gemspec

gem "puma"

gem "sqlite3"

gem "propshaft"

# Rails 8.1.3.1 calls `JSON.parse(json, options)` positionally in
# ActiveSupport::JSON.decode, but json 3.0 made those options keyword-only.
# spec/dummy/db/schema.rb has four `t.json` columns with `default: {}`, and
# SQLite's add_foreign_key rewrites those tables via copy_table, which
# deserialises each default -- so app:db:test:prepare aborts before a single
# example runs. Drop this pin once Rails ships a json 3 compatible
# activesupport.
gem "json", "< 3"

group :development, :test do
  gem "rspec-rails", "~> 8.0.4"
  gem "shoulda-matchers", "~> 7.0"
  gem "webmock", "~> 3.26"

  gem "factory_bot", "~> 6.5"
  gem "simplecov", require: false
  gem "brakeman", require: false
  gem "bundler-audit", require: false
  gem "foreman", require: false
end

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"

gem "tailwindcss-ruby", "~> 4.2"

gem "tailwindcss-rails", "~> 4.4"

# Apple Sign In
gem "standard_id-apple", "~> 0.4.0"

# Google Sign In
gem "standard_id-google", "~> 0.3.0"
