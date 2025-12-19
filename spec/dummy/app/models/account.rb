class Account < ApplicationRecord
  include StandardId::AccountAssociations
  include StandardId::AccountLocking
  include StandardId::AccountStatus

  validates :email, presence: true
  validates :name, presence: true
end
