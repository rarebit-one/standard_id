module StandardId
  class PasswordCredential < ApplicationRecord
    has_secure_password

    validates :principal, presence: true, uniqueness: true
    validates :password, length: { minimum: 8 }, confirmation: true, if: :validate_password?

    private

    def validate_password?
      password.present? || password_confirmation.present?
    end
  end
end
