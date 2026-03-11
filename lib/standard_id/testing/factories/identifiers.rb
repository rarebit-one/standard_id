FactoryBot.define do
  factory :standard_id_email_identifier, class: "StandardId::EmailIdentifier" do
    sequence(:value) { |n| "user#{n}@example.com" }

    trait :verified do
      verified_at { Time.current }
    end

    trait :unverified do
      verified_at { nil }
    end
  end

  factory :standard_id_phone_number_identifier, class: "StandardId::PhoneNumberIdentifier" do
    sequence(:value) { |n| "+1555#{(n % 10_000_000).to_s.rjust(7, '0')}" }

    trait :verified do
      verified_at { Time.current }
    end

    trait :unverified do
      verified_at { nil }
    end
  end

  factory :standard_id_username_identifier, class: "StandardId::UsernameIdentifier" do
    sequence(:value) { |n| "user_#{n}" }

    trait :verified do
      verified_at { Time.current }
    end

    trait :unverified do
      verified_at { nil }
    end
  end
end
