class CreateStandardIdPasswordlessChallenges < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_passwordless_challenges do |t|
      t.string :connection_type, null: false

      t.string :username, null: false
      t.string :code, null: false

      t.datetime :expires_at, null: false
      t.datetime :used_at

      t.string :ip_address
      t.text :user_agent

      t.timestamps
    end

    add_index :standard_id_passwordless_challenges, [:connection_type, :username, :code], name: "index_passwordless_challenges_on_lookup"
    add_index :standard_id_passwordless_challenges, :expires_at
    add_index :standard_id_passwordless_challenges, :used_at
  end
end
