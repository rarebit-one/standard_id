require "rails_helper"

module StandardId
  RSpec.describe PasswordCredential, type: :model do
    subject { described_class.new(principal: "user@example.com", password: "password123") }

    it { is_expected.to have_secure_password }

    it { is_expected.to validate_presence_of(:principal) }
    it { is_expected.to validate_uniqueness_of(:principal) }

    it { is_expected.to validate_length_of(:password).is_at_least(8) }
    it { is_expected.to validate_confirmation_of(:password) }
  end
end
