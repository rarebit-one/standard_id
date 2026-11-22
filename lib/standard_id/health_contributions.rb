# What StandardId offers standard_health, through its load hook. There is no
# dependency either way: without standard_health (or with a version older than
# the hook) the block never runs. With it, the block runs once, whichever gem
# is required first, and receives standard_health's contribution registry,
# which exposes only `contribute_check` and `contribute_env_vars`.
#
# Apps still decide: the check registers through `register_default_checks`
# (opt out with `standard_id_migrations: false`), and an env var the app
# declares in its own env_spec wins over the declaration here.
ActiveSupport.on_load(:standard_health) do |health|
  # Resolved by name when the check runs, so nothing here loads it early.
  health.contribute_check :standard_id_migrations, "StandardId::Checks::Migrations", critical: false

  # APP_ENVIRONMENT is the one deploy variable StandardId reads itself.
  # STANDARD_ID_BYPASS_CODE it never reads, but its production guard names it
  # and the apps feed c.passwordless.bypass_code from it. Provider credentials (GOOGLE_CLIENT_ID, APPLE_PRIVATE_KEY, ...) are not
  # declared here: which apply depends on the plugins an app registers.
  health.contribute_env_vars "standard_id" do
    recommended :APP_ENVIRONMENT,
      description: "Decides StandardId's production-only guards (the bypass-code refusal, the empty " \
                   "allowed_audiences warning, provider_misconfiguration = :raise). Any value other than staging, " \
                   "preview, development or test counts as production; unset falls back to Rails.env"
    forbidden :STANDARD_ID_BYPASS_CODE, in: %w[production],
      description: "Conventional source for c.passwordless.bypass_code, a fixed OTP for e2e tests. StandardId " \
                   "refuses to verify any code in production while a bypass code is configured"
  end
end
