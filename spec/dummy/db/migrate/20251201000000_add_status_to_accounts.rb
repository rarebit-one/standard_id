class AddStatusToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :status, :string, default: "active", null: false
    add_column :accounts, :activated_at, :datetime
    add_column :accounts, :deactivated_at, :datetime
  end
end
