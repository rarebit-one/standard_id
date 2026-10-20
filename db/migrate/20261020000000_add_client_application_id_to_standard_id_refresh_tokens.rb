# Binds each refresh token to the ClientApplication it was issued to, so the
# refresh_token grant can refuse a token whose application has since been
# deactivated or deleted (see StandardId::Oauth::RefreshTokenFlow
# #validate_client_application_liveness!). Set at mint from the grant's
# resolved client (authorization_code, client_credentials, any grant whose
# client_id names a registered application); copied to each rotated successor;
# NULL where the client_id is not an application (social sign-in refreshes as
# the provider's name) and on rows minted before this ran, which are bound on
# their next rotation.
#
# Deliberately NO foreign key: a deleted application must stay detectable as
# "gone" from the token's side, which a cascading or nullifying FK would erase.
# One nullable column, no default, no index, no backfill: metadata-only on
# PostgreSQL, so safe on a large table and under StrongMigrations. Until the
# migration has run the gem does not write or read the column; a deactivated
# application is still refused by client_id lookup, a deleted one is not.
class AddClientApplicationIdToStandardIdRefreshTokens < ActiveRecord::Migration[8.0]
  include StandardId::MigrationHelpers

  def change
    add_column :standard_id_refresh_tokens, :client_application_id, foreign_key_type
  end
end
