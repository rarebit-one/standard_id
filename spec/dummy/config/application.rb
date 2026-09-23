require_relative "boot"

require "rails"

require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Stand-in for a provider plugin gem's entry file, required here so the provider
# class is loaded at the same point in boot a real plugin loads it.
require_relative "dummy_social_provider"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Consumers (sidekick-web and others) run with strict loading on globally
    # and raising, so the dummy does too: a lazy association read in gem code
    # must fail here before it becomes a 500 in a host. The gem models hosts
    # exempt are exempted in config/initializers/strict_loading.rb; run with
    # STRICT_LOADING=full to drop those exemptions and see the backlog.
    config.active_record.strict_loading_by_default = true
    config.active_record.action_on_strict_loading_violation = :raise

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
