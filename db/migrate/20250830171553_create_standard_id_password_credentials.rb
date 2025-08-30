class CreateStandardIdPasswordCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_password_credentials, id: primary_key_type do |t|
      t.string :principal, null: false, index: { unique: true }
      t.string :password_digest, null: false

      t.timestamps
    end
  end
end
