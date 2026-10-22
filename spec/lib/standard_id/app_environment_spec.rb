require "rails_helper"

RSpec.describe StandardId::AppEnvironment do
  def with_app_environment(value)
    original = ENV.fetch("APP_ENVIRONMENT", nil)
    value.nil? ? ENV.delete("APP_ENVIRONMENT") : ENV["APP_ENVIRONMENT"] = value
    yield
  ensure
    original.nil? ? ENV.delete("APP_ENVIRONMENT") : ENV["APP_ENVIRONMENT"] = original
  end

  describe ".production?" do
    %w[staging preview development test].each do |name|
      it "is false for APP_ENVIRONMENT=#{name}, even under RAILS_ENV=production" do
        allow(Rails.env).to receive(:production?).and_return(true)

        with_app_environment(name) { expect(described_class.production?).to be(false) }
      end
    end

    it "is true for APP_ENVIRONMENT=production, even outside RAILS_ENV=production" do
      with_app_environment("production") { expect(described_class.production?).to be(true) }
    end

    # Fails closed: a misspelt value must never switch a production-only
    # guard (the bypass code, mock modes) off.
    it "is true for an unrecognised APP_ENVIRONMENT" do
      with_app_environment("prod") { expect(described_class.production?).to be(true) }
    end

    it "falls back to Rails.env when APP_ENVIRONMENT is unset or blank" do
      allow(Rails.env).to receive(:production?).and_return(true)
      with_app_environment(nil) { expect(described_class.production?).to be(true) }
      with_app_environment("  ") { expect(described_class.production?).to be(true) }

      allow(Rails.env).to receive(:production?).and_return(false)
      with_app_environment(nil) { expect(described_class.production?).to be(false) }
    end
  end
end
