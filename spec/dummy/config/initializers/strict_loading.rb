# Mirrors the gem-model exemptions consumer apps apply alongside
# `strict_loading_by_default = true` (see config/application.rb), so the dummy
# exercises the gem under the same rules the hosts run it under.
#
# Deliberately NOT exempted — these stay strict because hosts keep them strict,
# and a lazy read on them is a production 500:
#   RefreshToken, ClientApplication, ClientGrant, CodeChallenge, Account.
#
# The exemptions below are debt, not policy. Set STRICT_LOADING=full to drop
# them and surface the remaining lazy loads in gem code:
#
#   STRICT_LOADING=full bundle exec rspec
Rails.application.config.after_initialize do
  next if ENV["STRICT_LOADING"] == "full"

  [
    StandardId::Identifier,
    StandardId::Session,
    StandardId::Credential,
    StandardId::PasswordCredential,
    StandardId::ClientSecretCredential,
    StandardId::AuthorizationCode
  ].each { |klass| klass.strict_loading_by_default = false }
end
