FactoryBot.define do
  factory :standard_id_password_credential, class: "StandardId::PasswordCredential" do
    sequence(:login) { |n| "user#{n}@example.com" }
    password { "Password1!" }
    password_confirmation { "Password1!" }
  end

  factory :standard_id_credential, class: "StandardId::Credential" do
    association :identifier, factory: [:standard_id_email_identifier, :verified]
    association :credentialable, factory: :standard_id_password_credential

    # Sync login to identifier value so authentication works out of the box.
    # If you override credentialable after build, set login manually.
    after(:build) do |credential|
      credential.credentialable.login = credential.identifier.value
    end
  end

  factory :standard_id_client_secret_credential, class: "StandardId::ClientSecretCredential" do
    association :client_application, factory: :standard_id_client_application
    name { "Default Secret" }
    active { true }
  end
end
