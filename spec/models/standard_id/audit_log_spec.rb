require "rails_helper"

RSpec.describe StandardId::AuditLog, type: :model do
  let(:account) { Account.create!(name: "Test User", email: "audit-log-#{SecureRandom.hex(8)}@example.com") }

  describe "associations" do
    it { should belong_to(:actor).optional }
  end

  describe "validations" do
    subject do
      StandardId::AuditLog.new(
        event_type: "authentication.attempt.succeeded",
        occurred_at: Time.current
      )
    end

    it { should validate_presence_of(:event_type) }
    it { should validate_presence_of(:occurred_at) }
  end
end
