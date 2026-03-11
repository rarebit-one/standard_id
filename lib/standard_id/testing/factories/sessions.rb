FactoryBot.define do
  # BrowserSession requires an `account` association (belongs_to :account).
  # The host app must define an `:account` factory for this association to resolve.
  factory :standard_id_browser_session, class: "StandardId::BrowserSession" do
    association :account, factory: :account
    user_agent { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0" }
    sequence(:ip_address) { |n| "192.168.1.#{(n % 254) + 1}" }
    expires_at { StandardId::BrowserSession.expiry }

    trait :active do
      revoked_at { nil }
    end

    trait :expired do
      expires_at { 2.days.ago }
      revoked_at { nil }
    end

    trait :revoked do
      revoked_at { 1.day.ago }
    end

    trait :chrome do
      user_agent { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0" }
    end

    trait :firefox do
      user_agent { "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Firefox/121.0" }
    end

    trait :safari do
      user_agent { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/17.2" }
    end

    trait :edge do
      user_agent { "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Edg/120.0" }
    end
  end

  # DeviceSession requires an `account` association (belongs_to :account).
  # The host app must define an `:account` factory for this association to resolve.
  factory :standard_id_device_session, class: "StandardId::DeviceSession" do
    association :account, factory: :account
    device_agent { "App/1.0 (iPhone; iOS 17.2)" }
    sequence(:device_id) { |n| "device_#{n}" }
    sequence(:ip_address) { |n| "10.0.0.#{(n % 254) + 1}" }
    expires_at { StandardId::DeviceSession.expiry }
    last_refreshed_at { 30.minutes.ago }

    trait :active do
      revoked_at { nil }
      last_refreshed_at { 30.minutes.ago }
    end

    trait :expired do
      expires_at { 15.days.ago }
      revoked_at { nil }
    end

    trait :revoked do
      expires_at { 30.days.from_now }
      revoked_at { 5.days.ago }
    end

    trait :stale do
      expires_at { 30.days.from_now }
      revoked_at { nil }
      last_refreshed_at { 2.hours.ago }
    end

    trait :iphone do
      device_agent { "App/1.0 (iPhone; iOS 17.2)" }
    end

    trait :android do
      device_agent { "App/1.0 (Android; Samsung Galaxy S24)" }
    end

    trait :ipad do
      device_agent { "App/1.0 (iPad; iPadOS 17.2)" }
    end
  end

  # NOTE: ServiceSession inherits `belongs_to :account` from Session and adds
  # `belongs_to :owner` (polymorphic). Both are required.
  # By default, account and owner are distinct :account instances. Override one
  # or both if your test needs them to be the same object.
  # The host app must define an `:account` factory for these associations to resolve.
  factory :standard_id_service_session, class: "StandardId::ServiceSession" do
    association :account, factory: :account
    association :owner, factory: :account
    service_name { "test-service" }
    service_version { "1.0.0" }
    ip_address { "10.0.0.1" }
    user_agent { "ServiceClient/1.0" }
    expires_at { StandardId::ServiceSession.default_expiry }

    trait :active do
      revoked_at { nil }
    end

    trait :expired do
      expires_at { 30.days.ago }
      revoked_at { nil }
    end

    trait :revoked do
      expires_at { 90.days.from_now }
      revoked_at { 1.day.ago }
    end
  end
end
