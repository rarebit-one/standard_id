require "rails_helper"

RSpec.describe StandardId::RateLimitHandling do
  describe ".login_per_ip / .login_per_email" do
    let(:rate_limits) { StandardId.config.rate_limits }

    around do |example|
      snapshot = %i[login_per_ip login_per_email].index_with { |field| rate_limits[field] }
      example.run
    ensure
      snapshot.each { |field, value| rate_limits[field] = value }
    end

    it "defaults to 20 / 5" do
      expect(described_class.login_per_ip).to eq(20)
      expect(described_class.login_per_email).to eq(5)
    end

    it "reads rate_limits.login_per_ip / login_per_email" do
      rate_limits.login_per_ip = 40
      rate_limits.login_per_email = 9

      expect(described_class.login_per_ip).to eq(40)
      expect(described_class.login_per_email).to eq(9)
    end
  end
end
