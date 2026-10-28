# This file is copied to spec/ when you run "rails generate rspec:install"
require "spec_helper"

# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?

# StandardId::AppEnvironment reads APP_ENVIRONMENT before Rails.env. Specs that
# stub Rails.env to exercise production-only behaviour set APP_ENVIRONMENT
# themselves when they need it, so an exported value in the developer's shell
# must not leak in.
ENV.delete("APP_ENVIRONMENT")
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
require "bcrypt"
require "rspec/rails"
require "shoulda/matchers"
require "webmock/rspec"
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.

Rails.root.glob("../../spec/support/**/*.rb").sort.each { |f| require f }

# Ensures that the test database schema matches the current schema file.
# If there are pending migrations it will invoke `db:test:prepare` to
# recreate the test database by loading the schema.
# If you are not using ActiveRecord, you can remove these lines.
#
# On PostgreSQL (DATABASE_URL, the CI `test (postgres)` job) the schema is
# instead rebuilt by running every migration, the dummy app's and the gem's.
# schema.rb is dumped from SQLite, so loading it would skip exactly what this
# leg is for: the migrations' PG-only branches (jsonb, GIN, partial and
# CONCURRENTLY indexes). Refuses any database whose name does not look like a
# throwaway test database.
connection = ActiveRecord::Base.connection
if connection.adapter_name.match?(/postg/i)
  database = connection.current_database
  abort("Refusing to reset #{database.inspect}: not a test database") unless database.include?("test")

  connection.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
  connection.schema_cache.clear!
  ActiveRecord::Migration.verbose = false
  ActiveRecord::MigrationContext.new([
    Rails.root.join("db/migrate"),
    File.expand_path("../db/migrate", __dir__)
  ]).migrate
  ActiveRecord::Base.descendants.each(&:reset_column_information)
else
  begin
    ActiveRecord::Migration.maintain_test_schema!
  rescue ActiveRecord::PendingMigrationError => e
    abort e.to_s.strip
  end
end
RSpec.configure do |config|
  # If you"re not using ActiveRecord, or you"d prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also this infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

# Hash at bcrypt's floor for speed. `1` used to be set here, which reads like
# something faster than MIN_COST but isn't — generate_salt silently clamps
# anything below MIN_COST (4) up to it.
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST

# `clear_event_subscribers!` and the per-example notifier isolation that makes
# it safe live in spec/support/event_subscriber_isolation.rb.
