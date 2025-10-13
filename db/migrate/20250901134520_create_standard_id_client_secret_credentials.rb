class CreateStandardIdClientSecretCredentials < ActiveRecord::Migration[7.1]
  def change
    create_table :standard_id_client_secret_credentials, id: primary_key_type do |t|
      t.string :name, null: false

      t.references :client_application, type: primary_key_type, null: false, foreign_key: { to_table: :standard_id_client_applications }, index: true

      t.string :client_id, null: false, index: true # Denormalized for performance
      t.string :client_secret_digest, null: false

      t.string :scopes
      t.string :redirect_uris

      t.boolean :active, null: false, default: true
      t.datetime :revoked_at

      t.timestamps
    end
  end
end
