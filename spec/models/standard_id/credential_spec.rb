require "rails_helper"

module StandardId
  RSpec.describe Credential, type: :model do
    let(:account) { Account.create!(name: "Test User", email: "account@example.com") }
    let(:identifier) { EmailIdentifier.create!(account: account, value: "user@example.com") }

    it { is_expected.to belong_to(:identifier) }

    describe "associations" do
      it "can be associated with a password credential" do
        password_credential = PasswordCredential.create!(
          login: "user@example.com",
          password: "Password1!"
        )

        credential = Credential.create!(
          identifier: identifier,
          credentialable: password_credential
        )

        expect(credential.credentialable).to eq(password_credential)
        expect(credential.credentialable).to be_a(PasswordCredential)
      end
    end
  end
end
