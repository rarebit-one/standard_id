require "rails_helper"

RSpec.describe StandardId::Web::ResetPasswordConfirmForm, type: :model do
  let(:account) { Account.create!(email: "user@example.com", name: "User") }
  let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "user@example.com") }
  let!(:password_credential) { StandardId::PasswordCredential.create!(login: "user@example.com", password: "Password1!") }
  let!(:credential) { StandardId::Credential.create!(credentialable: password_credential, identifier: identifier) }

  describe "validations and submit" do
    it "fails when password is blank" do
      form = described_class.new(password_credential, password: "", password_confirmation: "")
      expect(form.submit).to eq(false)
      expect(form.errors[:password]).to include("cannot be blank")
    end

    it "fails when confirmation does not match" do
      form = described_class.new(password_credential, password: "NewPass1!ab", password_confirmation: "different")
      expect(form.submit).to eq(false)
      expect(form.errors[:password_confirmation]).to include("confirmation doesn't match")
    end

    it "fails when password is too short" do
      form = described_class.new(password_credential, password: "short", password_confirmation: "short")
      expect(form.submit).to eq(false)
      expect(form.errors[:password]).to include("must be at least 8 characters long")
    end

    it "updates password, destroys sessions, and returns true on success" do
      StandardId::BrowserSession.create!(account: account, user_agent: "RSpec", expires_at: 1.day.from_now)
      expect(account.sessions.count).to be >= 1

      form = described_class.new(password_credential, password: "NewPass1!ab", password_confirmation: "NewPass1!ab")

      expect(form.submit).to eq(true)

      # Password should be updated
      updated = StandardId::PasswordCredential.find(password_credential.id)
      expect(updated.authenticate("NewPass1!ab")).to be_truthy

      # Sessions should be destroyed
      expect(account.sessions.count).to eq(0)
    end
  end
end
