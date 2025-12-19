class AddLockingToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :locked, :boolean, default: false, null: false
    add_column :accounts, :locked_at, :datetime
    add_column :accounts, :lock_reason, :string
    add_column :accounts, :locked_by_id, :integer
    add_column :accounts, :locked_by_type, :string
    add_column :accounts, :unlocked_at, :datetime
    add_column :accounts, :unlocked_by_id, :integer
    add_column :accounts, :unlocked_by_type, :string

    add_index :accounts, :locked
  end
end
