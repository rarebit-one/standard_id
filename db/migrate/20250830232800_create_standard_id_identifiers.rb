class CreateStandardIdIdentifiers < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_identifiers, id: primary_key_type do |t|
      t.references :account, null: false, foreign_key: { to_table: StandardId.account_class.table_name }, index: true

      t.string :type, null: false

      t.string :value, null: false

      t.timestamp :verified_at

      t.timestamps
    end

    add_index :standard_id_identifiers, [:account_id, :type, :value], unique: true
  end
end
