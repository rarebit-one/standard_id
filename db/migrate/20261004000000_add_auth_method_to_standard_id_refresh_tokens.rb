# Records how the authentication behind a refresh token was established
# (`auth_method`: "password", "passwordless", "social", ...; `auth_provider`:
# the social provider's name, or NULL), so `config.login_method_policy` can be
# consulted again on the `refresh_token` grant with the ORIGINAL method. Each
# rotated token copies the values from its predecessor. See
# StandardId::AuthLineage.
#
# Two nullable columns, no default, no index, no backfill: metadata-only on
# PostgreSQL, so safe on a large table and under StrongMigrations. Rows minted
# before this ran keep NULL and reach the policy as `:unspecified`. Until the
# migration has run the gem simply does not write the columns.
class AddAuthMethodToStandardIdRefreshTokens < ActiveRecord::Migration[8.0]
  def change
    add_column :standard_id_refresh_tokens, :auth_method, :string
    add_column :standard_id_refresh_tokens, :auth_provider, :string
  end
end
