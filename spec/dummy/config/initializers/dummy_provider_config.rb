# Writes a provider plugin's config fields from a plain initializer — exactly the
# form the install template and the plugin READMEs document.
#
# Before the `standard_id.provider_config_schemas` initializer existed, this
# raised StandardId::ConfigurationError: the fields were declared only by
# `ProviderRegistry.register`, called from the plugin Railtie's
# `config.after_initialize`, which runs long after :load_config_initializers.
#
# It lives in the dummy app deliberately. A regression here does not fail one
# example — it stops the app booting, so the entire suite goes red and cannot be
# quietly ignored.
StandardId.configure do |config|
  config.social.dummy_social_client_id = "dummy-client-id"
  config.social.dummy_social_client_secret = "dummy-client-secret"
end
