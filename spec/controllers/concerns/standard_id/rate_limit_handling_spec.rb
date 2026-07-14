require "rails_helper"

RSpec.describe StandardId::RateLimitHandling do
  describe "login rate-limit deprecation aliases (.login_per_ip / .login_per_email)" do
    let(:rate_limits) { StandardId.config.rate_limits }

    around do |example|
      snapshot = %i[login_per_ip login_per_email password_login_per_ip password_login_per_email]
                   .index_with { |field| rate_limits[field] }
      example.run
    ensure
      snapshot.each { |field, value| rate_limits[field] = value }
    end

    it "falls back to the shared default (20 / 5) when neither name is customised" do
      expect(described_class.login_per_ip).to eq(20)
      expect(described_class.login_per_email).to eq(5)
    end

    it "honours the deprecated password_login_* field when only it is set" do
      rate_limits.password_login_per_ip = 33
      rate_limits.password_login_per_email = 7

      expect(described_class.login_per_ip).to eq(33)
      expect(described_class.login_per_email).to eq(7)
    end

    it "uses the new login_* alias when only it is set" do
      rate_limits.login_per_ip = 40
      rate_limits.login_per_email = 9

      expect(described_class.login_per_ip).to eq(40)
      expect(described_class.login_per_email).to eq(9)
    end

    it "lets the new alias win when both names are set" do
      rate_limits.login_per_ip = 40
      rate_limits.password_login_per_ip = 33

      expect(described_class.login_per_ip).to eq(40)
    end
  end
end
