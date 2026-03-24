require "rails_helper"

RSpec.describe StandardId::Web::SignupForm, type: :model do
  describe "validations" do
    it "requires a valid email" do
      form = described_class.new(email: "bad", password: "Password1!", password_confirmation: "Password1!")
      expect(form).not_to be_valid
      expect(form.errors[:email]).to be_present
    end

    it "requires password with minimum length" do
      form = described_class.new(email: "user@example.com", password: "short", password_confirmation: "short")
      expect(form).not_to be_valid
      expect(form.errors[:password]).to be_present
    end

    it "requires matching password confirmation" do
      form = described_class.new(email: "user@example.com", password: "Password1!", password_confirmation: "different")
      expect(form).not_to be_valid
      expect(form.errors[:password_confirmation]).to be_present
    end
  end

  describe "#submit" do
    it "creates account, identifier, credential, and password_credential, and returns true" do
      form = described_class.new(email: "newuser@example.com", password: "Password1!", password_confirmation: "Password1!")

      expect {
        expect(form.submit).to eq(true)
      }.to change(Account, :count).by(1)
       .and change(StandardId::EmailIdentifier, :count).by(1)
       .and change(StandardId::PasswordCredential, :count).by(1)
       .and change(StandardId::Credential, :count).by(1)

      account = form.account
      expect(account).to be_present
      expect(account.email).to eq("newuser@example.com")

      identifier = StandardId::EmailIdentifier.find_by!(value: "newuser@example.com")
      expect(identifier.account).to eq(account)

      password_cred = StandardId::PasswordCredential.find_by!(login: "newuser@example.com")
      expect(password_cred.credential).to be_present
      expect(password_cred.credential.identifier).to eq(identifier)
    end

    it "adds base errors and returns false when nested create fails (e.g., duplicate email login)" do
      # Pre-create a conflicting password credential
      existing = StandardId::PasswordCredential.create!(login: "dup@example.com", password: "Password1!")
      # Need an identifier+credential to satisfy associations; create a dummy account/identifier
      acc = Account.create!(name: "Dup", email: "dup@example.com")
      idf = StandardId::EmailIdentifier.create!(account: acc, value: "dup@example.com", verified_at: Time.current)
      StandardId::Credential.create!(credentialable: existing, identifier: idf)

      form = described_class.new(email: "dup@example.com", password: "Password1!", password_confirmation: "Password1!")
      expect(form.submit).to eq(false)
      expect(form.errors[:base]).to be_present
    end
  end
end
