class CreateStandardIdAuthorizationCodes < ActiveRecord::Migration[8.0]
  include StandardId::MigrationHelpers

  def change
    create_table :standard_id_authorization_codes, id: primary_key_type do |t|
      # Link to account when available (can be nil for pre-auth flows)
      t.references :account, null: true, foreign_key: true, index: true, type: foreign_key_type

      # Opaque auth code hash (SHA256 of the plaintext code), unique for lookup
      t.string :code_hash, null: false

      # OAuth client binding and redirect URI binding
      t.string :client_id, null: false
      t.text :redirect_uri, null: false

      # Optional OAuth/OIDC extras
      t.string :scope
      t.string :audience
      t.string :nonce

      # PKCE
      t.string :code_challenge
      t.string :code_challenge_method

      # Lifecycle
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      # Provider and custom metadata if needed
      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :metadata, default: {}, null: false
        t.index :metadata, using: :gin
      else
        t.json :metadata, default: {}, null: false
      end

      t.timestamps

      # Indexes
      t.index :code_hash, unique: true
      t.index [:client_id, :expires_at]
      t.index [:account_id, :expires_at]
      t.index :expires_at
      t.index :consumed_at
    end
  end
end
