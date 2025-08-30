source "https://rubygems.org"

ruby file: ".ruby-version"

# Specify your gem's dependencies in standard_id.gemspec.
gemspec

gem "puma"

gem "sqlite3"

gem "propshaft"

group :development, :test do
  gem "rspec-rails", "~> 8.0.0"
  gem "shoulda-matchers", "~> 6.0"
end

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
