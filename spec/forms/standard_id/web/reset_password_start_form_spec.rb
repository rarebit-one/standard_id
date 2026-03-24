require "rails_helper"

RSpec.describe StandardId::Web::ResetPasswordStartForm, type: :model do
  describe "validations" do
    it "requires an email" do
      form = described_class.new(email: "")
      expect(form).not_to be_valid
      expect(form.errors[:email]).to include("Please enter your email address")
    end

    it "requires valid email format" do
      form = described_class.new(email: "bad")
      expect(form).not_to be_valid
      expect(form.errors[:email]).to be_present
    end
  end

  describe "#submit" do
    let(:account) { Account.create!(email: "user@example.com", name: "User") }
    let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "user@example.com") }
    let!(:password_credential) { StandardId::PasswordCredential.create!(login: "user@example.com", password: "Password1!") }
    let!(:credential) { StandardId::Credential.create!(credentialable: password_credential, identifier: identifier) }

    it "returns true and sets token when account has password credential" do
      form = described_class.new(email: "user@example.com")
      expect(form.submit).to eq(true)
      expect(form.token).to be_present
      expect(form.password_credential).to eq(password_credential)
    end

    it "returns true and sets no token when email not found" do
      form = described_class.new(email: "missing@example.com")
      expect(form.submit).to eq(true)
      expect(form.token).to be_nil
      expect(form.password_credential).to be_nil
    end
  end
end
