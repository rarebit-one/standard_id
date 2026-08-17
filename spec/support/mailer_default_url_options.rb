# Rails-edge compatibility shim for `type: :mailer` example groups.
#
# Rails main froze the fallback value of ActionDispatch::Routing::UrlFor's
# `default_url_options` class attribute:
#
#   # actionpack/lib/action_dispatch/routing/url_for.rb
#   included do
#     unless method_defined?(:default_url_options)
#       ...
#       self.default_url_options = {}.freeze   # <- newly frozen
#     end
#   end
#
# rspec-rails still mutates that hash in place when it builds a mailer example
# group (rspec-rails 8.0.4 and rspec-rails main alike):
#
#   # lib/rspec/rails/example/mailer_example_group.rb
#   included do
#     include ::Rails.application.routes.url_helpers
#     options = ::Rails.configuration.action_mailer.default_url_options || {}
#     options.each { |key, value| default_url_options[key] = value }
#   end
#
# Because spec/dummy sets `config.action_mailer.default_url_options`, that loop
# runs and raises `FrozenError: can't modify frozen Hash: {}` while the
# `RSpec.describe ..., type: :mailer` line is being evaluated — i.e. at spec
# load time, before any example runs.
#
# The mutation lives in rspec-rails, but the group-level attribute is ours to
# seed. UrlFor only installs (and freezes) its own attribute
# `unless method_defined?(:default_url_options)`, so defining an unfrozen one on
# the RSpec base class ahead of time makes UrlFor's `included` hook a no-op and
# leaves rspec-rails mutating a hash it is allowed to mutate.
#
# It is seeded with the app's configured options, so the values rspec-rails
# writes into it are the values it already holds — the hash is shared across
# groups, but every writer writes the same thing.
#
# Remove once rspec-rails assigns (`self.default_url_options = ...`) instead of
# mutating. Tracked in rarebit-one/rarebit-sre#220.
if defined?(RSpec::Rails::MailerExampleGroup) &&
   !RSpec::Core::ExampleGroup.respond_to?(:default_url_options)
  RSpec::Core::ExampleGroup.class_attribute(
    :default_url_options,
    default: (Rails.configuration.action_mailer.default_url_options || {}).dup
  )
end
