require "rails_helper"

RSpec.describe StandardId::SocialAuthentication do
  let(:dummy_class) do
    Class.new(ActionController::Base) do
      include StandardId::SocialAuthentication
    end
  end

  let(:instance) { dummy_class.new }
  let(:social_info) { { email: "user@example.com" } }
  let(:provider_tokens) { { id_token: "id-token" } }
  let(:account) { double("Account") }

  describe "#run_social_callback" do
    it "passes only the keys accepted by the callback" do
      event_received = nil
      StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) do |event|
        event_received = event
      end

      instance.send(
        :run_social_callback,
        provider: "google",
        social_info: social_info,
        provider_tokens: provider_tokens,
        account: account
      )

      expect(event_received).to be_present
      expect(event_received[:account]).to eq(account)
      expect(event_received[:provider]).to eq("google")
      expect(event_received[:social_info]).to match(social_info)
      expect(event_received[:tokens]).to match(provider_tokens)
    end
  end

  describe "#find_or_create_account_from_social" do
    let(:email) { "social-#{SecureRandom.hex(4)}@example.com" }
    let(:provider) { double("Provider", provider_name: "google") }

    before do
      allow(instance).to receive(:provider).and_return(provider)
      allow(instance).to receive(:resolve_account_attributes).and_return({ name: "Test", email: email })
    end

    context "when creating a new account" do
      context "with email_verified: true (boolean)" do
        it "verifies the email identifier" do
          info = { email: email, email_verified: true }.with_indifferent_access

          account = instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).to be_verified
        end
      end

      context "with email_verified: 'true' (string)" do
        it "verifies the email identifier" do
          info = { email: email, email_verified: "true" }.with_indifferent_access

          account = instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).to be_verified
        end
      end

      context "with email_verified: false" do
        it "does not verify the email identifier" do
          info = { email: email, email_verified: false }.with_indifferent_access

          account = instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).not_to be_verified
        end
      end

      context "with email_verified: 'false' (string)" do
        it "does not verify the email identifier" do
          info = { email: email, email_verified: "false" }.with_indifferent_access

          account = instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).not_to be_verified
        end
      end

      context "with email_verified omitted" do
        it "does not verify the email identifier" do
          info = { email: email }.with_indifferent_access

          account = instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).not_to be_verified
        end
      end
    end
  end
end
