class CreateStandardIdCodeChallenges < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_code_challenges do |t|
      t.string :realm, null: false         # e.g., authentication, verify_email, verify_phone, account_confirmation, unlock_account
      t.string :channel, null: false       # e.g., email, sms
      t.string :target, null: false        # recipient address (email/phone), normalized by caller
      t.string :code, null: false

      t.datetime :expires_at, null: false
      t.datetime :used_at

      t.string :ip_address
      t.text :user_agent

      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :metadata, default: {}, null: false
        t.index :metadata, using: :gin
      else
        t.json :metadata, default: {}, null: false
      end

      t.timestamps
    end

    add_index :standard_id_code_challenges, [:realm, :channel, :target, :code], name: "index_code_challenges_on_lookup"
    add_index :standard_id_code_challenges, :expires_at
    add_index :standard_id_code_challenges, :used_at
  end
end
