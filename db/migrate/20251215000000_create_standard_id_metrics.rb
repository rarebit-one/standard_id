class CreateStandardIdMetrics < ActiveRecord::Migration[8.0]
  def change
    create_table :standard_id_metrics, id: primary_key_type do |t|
      t.string :name, null: false
      t.datetime :time_bucket, null: false
      t.string :status, default: "success", null: false
      t.bigint :count, default: 0, null: false
      t.float :total_duration, default: 0.0, null: false

      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :dimensions, default: {}, null: false
      else
        t.json :dimensions, default: {}, null: false
      end

      t.timestamps
    end

    add_index :standard_id_metrics,
              [:name, :time_bucket, :status, :dimensions],
              unique: true,
              name: "index_metrics_unique_bucket"

    if connection.adapter_name.downcase.include?("postgres")
      add_index :standard_id_metrics, :dimensions, using: :gin
    end
  end
end
