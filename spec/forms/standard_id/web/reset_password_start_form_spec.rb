require "rails_helper"

RSpec.describe StandardId::Web::ResetPasswordStartForm, type: :model do
  let(:reset_url_template) { "https://example.test/reset_password/confirm?token={token}" }

  describe "validations" do
    it "requires an email" do
      form = described_class.new(email: "", reset_url_template: reset_url_template)
      expect(form).not_to be_valid
      expect(form.errors[:email]).to include("Please enter your email address")
    end

    it "requires valid email format" do
      form = described_class.new(email: "bad", reset_url_template: reset_url_template)
      expect(form).not_to be_valid
      expect(form.errors[:email]).to be_present
    end
  end

  describe "#submit" do
    let(:account) { Account.create!(email: "user@example.com", name: "User") }
    let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: "user@example.com") }
    let!(:password_credential) { StandardId::PasswordCredential.create!(login: "user@example.com", password: "Password1!") }
    let!(:credential) { StandardId::Credential.create!(credentialable: password_credential, identifier: identifier) }

    it "returns true and enqueues the delivery job when the email is valid" do
      form = described_class.new(email: "user@example.com", reset_url_template: reset_url_template)

      expect(StandardId::PasswordResetDeliveryJob).to receive(:perform_later).with(
        email: "user@example.com",
        reset_url_template: reset_url_template
      )

      expect(form.submit).to eq(true)
    end

    it "returns true and still enqueues the delivery job when the email does not match any account" do
      # User enumeration defence: behaviour must be identical whether or not
      # the account exists. The job itself no-ops when lookup fails.
      form = described_class.new(email: "missing@example.com", reset_url_template: reset_url_template)

      expect(StandardId::PasswordResetDeliveryJob).to receive(:perform_later).with(
        email: "missing@example.com",
        reset_url_template: reset_url_template
      )

      expect(form.submit).to eq(true)
    end

    it "does not enqueue the job when validation fails" do
      form = described_class.new(email: "not-an-email", reset_url_template: reset_url_template)

      expect(StandardId::PasswordResetDeliveryJob).not_to receive(:perform_later)

      expect(form.submit).to eq(false)
    end
  end
end
