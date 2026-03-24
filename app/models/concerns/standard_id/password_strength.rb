module StandardId
  module PasswordStrength
    extend ActiveSupport::Concern

    included do
      validate :password_meets_strength_requirements, if: -> { password.present? }
    end

    private

    def password_meets_strength_requirements
      config = StandardId.config.password

      if password.length < config.minimum_length
        errors.add(:password, "must be at least #{config.minimum_length} characters long")
      end

      if config.require_uppercase && password !~ /[A-Z]/
        errors.add(:password, "must include at least one uppercase letter")
      end

      if config.require_numbers && password !~ /\d/
        errors.add(:password, "must include at least one number")
      end

      if config.require_special_chars && password !~ /[^a-zA-Z0-9]/
        errors.add(:password, "must include at least one special character")
      end
    end
  end
end
