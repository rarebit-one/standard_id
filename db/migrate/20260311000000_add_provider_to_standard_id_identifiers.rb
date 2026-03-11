# Adds provider tracking to identifiers for social login link validation.
#
# After running this migration, existing identifiers will have provider=NULL.
# The strict link strategy treats NULL provider as "pre-migration" and allows
# linking, so existing users are not blocked. However, this means pre-migration
# accounts are not fully protected by the strict strategy until their provider
# is populated — either by logging in again via social, or by running a
# backfill (e.g. UPDATE standard_id_identifiers SET provider = 'email'
# WHERE provider IS NULL AND type = 'StandardId::EmailIdentifier').
class AddProviderToStandardIdIdentifiers < ActiveRecord::Migration[8.0]
  def change
    add_column :standard_id_identifiers, :provider, :string
    add_index :standard_id_identifiers, [:account_id, :provider]
  end
end
