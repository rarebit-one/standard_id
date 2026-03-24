require "rails_helper"
require "active_support/testing/time_helpers"

module StandardId
  RSpec.describe PasswordCredential, type: :model do
    include ActiveSupport::Testing::TimeHelpers

    it_behaves_like "a credentialable"

    let(:account) { Account.create!(name: "Test User", email: "account@example.com") }
    let(:identifier) { EmailIdentifier.create!(account: account, value: "user@example.com") }

    subject { described_class.new(login: "user@example.com", password: "Password1!") }

    it { is_expected.to have_one(:credential) }
    it { is_expected.to delegate_method(:account).to(:credential) }

    it { is_expected.to have_secure_password }

    it { is_expected.to validate_presence_of(:login) }
    it "validates uniqueness of login" do
      subject.save!
      duplicate = described_class.new(login: "user@example.com", password: "Password4!x")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:login]).to include("has already been taken")
    end

    it { is_expected.to validate_confirmation_of(:password) }

    describe "password strength validation" do
      it "rejects passwords shorter than configured minimum" do
        cred = described_class.new(login: "test@example.com", password: "Sh0rt!")
        expect(cred).not_to be_valid
        expect(cred.errors[:password]).to include(/at least 8 characters/)
      end

      it "rejects passwords without uppercase when required" do
        allow(StandardId.config.password).to receive(:require_uppercase).and_return(true)
        cred = described_class.new(login: "test@example.com", password: "lowercase1!")
        expect(cred).not_to be_valid
        expect(cred.errors[:password]).to include(/uppercase/)
      end

      it "rejects passwords without numbers when required" do
        allow(StandardId.config.password).to receive(:require_numbers).and_return(true)
        cred = described_class.new(login: "test@example.com", password: "NoNumbers!!")
        expect(cred).not_to be_valid
        expect(cred.errors[:password]).to include(/number/)
      end

      it "rejects passwords without special chars when required" do
        allow(StandardId.config.password).to receive(:require_special_chars).and_return(true)
        cred = described_class.new(login: "test@example.com", password: "NoSpecial1A")
        expect(cred).not_to be_valid
        expect(cred.errors[:password]).to include(/special character/)
      end

      it "accepts passwords meeting all requirements" do
        cred = described_class.new(login: "test@example.com", password: "Strong1!Pass")
        cred.valid?
        strength_errors = cred.errors[:password].select { |e| e.include?("must") }
        expect(strength_errors).to be_empty
      end
    end

    describe "remember_me token generation" do
      let!(:credential) do
        described_class.create!(
          login: "user@example.com",
          password: "Password1!",
          password_confirmation: "Password1!"
        )
      end

      it "generates a token and finds record via find_by_token_for" do
        token = credential.generate_token_for(:remember_me)
        expect(token).to be_a(String)
        expect(token.length).to be > 10

        found = described_class.find_by_token_for(:remember_me, token)
        expect(found).to eq(credential)
      end

      it "invalidates the token when password changes" do
        token = credential.generate_token_for(:remember_me)
        expect(described_class.find_by_token_for(:remember_me, token)).to eq(credential)

        # Changing password updates password_digest, which our token depends on
        credential.update!(password: "NewPass1!abc", password_confirmation: "NewPass1!abc")

        expect(described_class.find_by_token_for(:remember_me, token)).to be_nil

        new_token = credential.generate_token_for(:remember_me)
        expect(described_class.find_by_token_for(:remember_me, new_token)).to eq(credential)
      end

      it "expires the token after the configured duration" do
        freeze_time do
          token = credential.generate_token_for(:remember_me)
          expect(described_class.find_by_token_for(:remember_me, token)).to eq(credential)

          travel 30.days + 1.second
          expect(described_class.find_by_token_for(:remember_me, token)).to be_nil
        end
      end
    end
  end
end
