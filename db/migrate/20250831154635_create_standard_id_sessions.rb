class CreateStandardIdSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_sessions, id: primary_key_type do |t|
      t.references :account, type: primary_key_type, null: false, foreign_key: true, index: true

      # STI type column
      t.string :type, null: false, index: true

      # Base session columns
      t.string :lookup_hash, null: false, index: { unique: true }
      t.string :token_digest, null: false
      t.string :ip_address
      t.datetime :expires_at, null: false
      t.datetime :revoked_at

      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :metadata, default: {}, null: false
        t.index :metadata, using: :gin
      else
        t.json :metadata, default: {}, null: false
      end

      # BrowserSession columns
      t.text :user_agent

      # DeviceSession columns
      t.string :device_id
      t.text :device_agent
      t.datetime :last_refreshed_at

      # ServiceSession columns
      t.references :owner, type: primary_key_type, polymorphic: true, null: true, index: true
      t.string :service_name
      t.string :service_version

      t.timestamps

      t.index [:lookup_hash, :expires_at, :revoked_at]
      t.index [:expires_at, :revoked_at]
      t.index [:account_id, :type, :expires_at]
    end
  end
end
