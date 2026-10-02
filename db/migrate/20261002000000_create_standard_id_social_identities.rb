# Stores the social provider's stable subject id (`sub`) per account, so a
# returning social login is matched on (provider, sub) instead of on the email
# address alone.
#
# Before this table, `find_or_create_account_from_social` linked a provider
# login to whichever account held an email identifier with the same address,
# without looking at `sub` or `email_verified`. Under `link_strategy:
# :trust_provider`, or for an identifier with a NULL provider, any token that
# claimed an address could sign in as that address's account.
#
# New, empty table: nothing existing is rewritten, and no row is backfilled.
# Each existing social user gets a row on their next successful login (when the
# provider reports the email as verified). Until the migration has run, the
# gem skips subject matching and logs a warning, but still refuses to link an
# existing account to an unverified provider email.
#
# Both foreign keys cascade so the host's account- and identifier-deletion
# paths keep working unchanged: deleting the email identifier a link was made
# through removes the link, and the next login has to re-link on a verified
# email.
class CreateStandardIdSocialIdentities < ActiveRecord::Migration[8.0]
  include StandardId::MigrationHelpers

  def change
    create_table :standard_id_social_identities, id: primary_key_type do |t|
      t.references :account, type: foreign_key_type, null: false, index: true,
        foreign_key: { to_table: StandardId.account_class.table_name, on_delete: :cascade }
      t.references :identifier, type: foreign_key_type, null: false, index: false,
        foreign_key: { to_table: :standard_id_identifiers, on_delete: :cascade }

      t.string :provider, null: false
      t.string :subject, null: false

      t.timestamps
    end

    # One account per provider subject.
    add_index :standard_id_social_identities, [:provider, :subject], unique: true
    # One subject per provider for a given email identifier: a second subject
    # claiming the same address is refused as a possible takeover.
    add_index :standard_id_social_identities, [:identifier_id, :provider], unique: true,
      name: "index_standard_id_social_identities_on_identifier_and_provider"
  end
end
