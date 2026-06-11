class CreateStandardIdClientGrants < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_client_grants, id: primary_key_type do |t|
      # The account that granted consent. Required — consent is per-user.
      t.references :account, null: false, foreign_key: true, index: true, type: foreign_key_type

      # The OAuth client the consent was granted to. Stored as client_id (the
      # public identifier) to mirror authorization_codes' client binding.
      t.string :client_id, null: false

      # The space-delimited scope string the user approved. Lets a future
      # change require re-consent when a client requests a broader scope than
      # was previously granted.
      t.string :scope

      t.timestamps

      # One active grant per (account, client). Re-approving updates the row.
      t.index [:account_id, :client_id], unique: true, name: "idx_standard_id_client_grants_on_account_client"
      t.index :client_id
    end
  end
end
