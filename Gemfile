source "https://rubygems.org"

ruby file: ".ruby-version"

# Specify your gem's dependencies in standard_id.gemspec.
gemspec

gem "puma"

gem "sqlite3"

gem "propshaft"

group :development, :test do
  gem "ostruct"
  gem "rspec-rails", "~> 8.0.3"
  gem "shoulda-matchers", "~> 7.0"
  gem "webmock", "~> 3.26"

  gem "brakeman", require: false
  gem "bundler-audit", require: false
end

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"

gem "tailwindcss-ruby", "~> 4.2"

gem "tailwindcss-rails", "~> 4.4"

# Apple Sign In
gem "standard_id-apple", "~> 0.1.2"

# Google Sign In
gem "standard_id-google", "~> 0.1.2"
