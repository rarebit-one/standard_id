class CreateStandardIdClientApplications < ActiveRecord::Migration[7.1]
  def change
    create_table :standard_id_client_applications, id: primary_key_type do |t|
      # Polymorphic owner association (Account, Organization, etc.)
      t.references :owner, type: primary_key_type, null: false, polymorphic: true, index: true

      # Basic client information
      t.string :name, null: false
      t.text :description

      # OAuth client identifier
      t.string :client_id, null: false, index: { unique: true }

      # OAuth configuration
      t.text :redirect_uris, null: false
      t.string :scopes, default: "openid profile email"
      t.string :grant_types, default: "authorization_code refresh_token"
      t.string :response_types, default: "code"

      # PKCE configuration
      t.boolean :require_pkce, null: false, default: true
      t.string :code_challenge_methods, default: "S256"

      # Token configuration
      t.integer :access_token_lifetime, default: 3600 # 1 hour in seconds
      t.integer :refresh_token_lifetime, default: 2592000 # 30 days in seconds
      t.integer :authorization_code_lifetime, default: 600 # 10 minutes in seconds

      # Client type and security
      t.string :client_type, null: false, default: "confidential" # confidential or public
      t.boolean :require_consent, null: false, default: true

      # Lifecycle management
      t.boolean :active, null: false, default: true
      t.datetime :deactivated_at

      # Metadata for extensibility
      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :metadata, default: {}, null: false
      else
        t.json :metadata, default: {}, null: false
      end

      t.timestamps

      # Indexes
      t.index [:owner_type, :owner_id]
      t.index :active
      t.index :client_type
    end

    if connection.adapter_name.downcase.include?("postgres")
      add_index :standard_id_client_applications, :metadata, if_not_exists: true, using: :gin
    end
  end
end
