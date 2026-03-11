class CreateStandardIdRefreshTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_refresh_tokens, id: primary_key_type do |t|
      t.references :account, type: primary_key_type, null: false, foreign_key: true, index: true
      t.references :session, type: primary_key_type, null: true, foreign_key: { to_table: :standard_id_sessions }, index: true

      t.string :token_digest, null: false, index: { unique: true }
      t.datetime :expires_at, null: false
      t.datetime :revoked_at

      t.references :previous_token, type: primary_key_type, null: true, foreign_key: { to_table: :standard_id_refresh_tokens }, index: true

      t.timestamps

      t.index [:account_id, :revoked_at], name: "idx_on_account_id_revoked_at_refresh_tokens"
      t.index [:session_id, :revoked_at], name: "idx_on_session_id_revoked_at_refresh_tokens"
      t.index [:expires_at, :revoked_at], name: "idx_on_expires_at_revoked_at_refresh_tokens"
    end
  end
end
