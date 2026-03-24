module StandardId
  class PasswordCredential < ApplicationRecord
    include StandardId::Credentiable
    include StandardId::PasswordStrength

    has_secure_password

    generates_token_for :remember_me, expires_in: 30.days do
      password_digest
    end

    generates_token_for :password_reset, expires_in: 20.minutes do
      password_digest
    end

    validates :login, presence: true, uniqueness: true
    validates :password, confirmation: true, if: :validate_password?

    private

    def validate_password?
      password.present? || password_confirmation.present?
    end
  end
end
