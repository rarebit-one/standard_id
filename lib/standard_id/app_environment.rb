module StandardId
  # Whether this deploy is production, for every check the gem makes.
  #
  # The estate convention (shared by standard_audit, standard_health and
  # standard_singpass) is the APP_ENVIRONMENT variable, falling back to
  # Rails.env: a physically-staging box runs RAILS_ENV=production with
  # APP_ENVIRONMENT=staging, so Rails.env alone would call staging production.
  #
  # It fails closed. Only the known non-production names count as
  # non-production; any other value (a typo such as "prod", or "production")
  # is production, so a misconfigured variable can never switch off a
  # production-only guard.
  module AppEnvironment
    NON_PRODUCTION = %w[staging preview development test].freeze

    module_function

    # @return [Boolean]
    def production?
      app_env = ENV["APP_ENVIRONMENT"].to_s.strip
      return !NON_PRODUCTION.include?(app_env) unless app_env.empty?

      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
    end
  end
end
