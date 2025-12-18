class CreateStandardIdAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_audit_logs, id: primary_key_type do |t|
      t.string :event_type, null: false
      t.string :request_id
      t.references :actor, type: primary_key_type, polymorphic: true, null: true, index: true
      t.references :target, type: primary_key_type, polymorphic: true, null: true, index: true
      t.string :ip_address
      t.datetime :occurred_at, null: false

      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :metadata, default: {}, null: false
        t.index :metadata, using: :gin
      else
        t.json :metadata, default: {}, null: false
      end

      t.timestamps

      t.index :event_type
      t.index :request_id
      t.index :occurred_at, order: :desc
      t.index :ip_address
    end
  end
end
