# Dummy app :account factory for testing StandardId factories that declare
# `association :account`. Host apps provide their own :account factory.
FactoryBot.define do
  factory :account, class: "Account" do
    sequence(:name) { |n| "Test User #{n}" }
    sequence(:email) { |n| "factory-test-#{n}@example.com" }
  end
end
