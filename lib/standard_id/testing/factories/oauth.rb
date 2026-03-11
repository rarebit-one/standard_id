FactoryBot.define do
  # ClientApplication requires a polymorphic `owner` association.
  # The host app must define an `:account` factory for this association to resolve.
  factory :standard_id_client_application, class: "StandardId::ClientApplication" do
    association :owner, factory: :account
    sequence(:name) { |n| "Test App #{n}" }
    redirect_uris { "https://example.com/callback" }
    scopes { "openid profile email" }
    grant_types { "authorization_code refresh_token" }
    response_types { "code" }
    client_type { "confidential" }
    require_pkce { true }
    code_challenge_methods { "S256" }
    access_token_lifetime { 3600 }
    refresh_token_lifetime { 2_592_000 }
    authorization_code_lifetime { 600 }
    active { true }

    trait :public_client do
      client_type { "public" }
    end

    trait :inactive do
      active { false }
      deactivated_at { Time.current }
    end

    # Replaces the default grant_types value. To combine with other grant types,
    # set grant_types explicitly: grant_types { "authorization_code client_credentials" }
    trait :with_client_credentials do
      grant_types { "client_credentials" }
    end
  end

  factory :standard_id_code_challenge, class: "StandardId::CodeChallenge" do
    realm { "authentication" }
    channel { "email" }
    sequence(:target) { |n| "user#{n}@example.com" }
    code { SecureRandom.random_number(10**6).to_s.rjust(6, "0") }
    expires_at { 10.minutes.from_now }

    trait :expired do
      expires_at { 5.minutes.ago }
    end

    trait :used do
      used_at { Time.current }
    end

    trait :for_verification do
      realm { "verification" }
    end

    trait :for_sms do
      channel { "sms" }
      sequence(:target) { |n| "+1555#{(n % 10_000_000).to_s.rjust(7, '0')}" }
    end
  end

  # AuthorizationCode has `belongs_to :account, optional: true`.
  # client_id is a plain string (no FK to ClientApplication) — intentionally
  # unlinked so tests can create authorization codes without a full OAuth setup.
  factory :standard_id_authorization_code, class: "StandardId::AuthorizationCode" do
    transient do
      plaintext_code { SecureRandom.hex(20) }
    end

    association :account, factory: :account
    code_hash { StandardId::AuthorizationCode.hash_for(plaintext_code) }
    client_id { SecureRandom.hex(16) }
    redirect_uri { "https://example.com/callback" }
    scope { "openid profile" }
    issued_at { Time.current }
    expires_at { 10.minutes.from_now }

    trait :expired do
      expires_at { 5.minutes.ago }
    end

    trait :consumed do
      consumed_at { Time.current }
    end

    trait :with_pkce do
      code_challenge { SecureRandom.hex(32) }
      code_challenge_method { "S256" }
    end
  end
end
