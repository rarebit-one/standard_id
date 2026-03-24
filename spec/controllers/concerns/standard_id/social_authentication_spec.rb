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
      subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) do |event|
        event_received = event
      end

      begin
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
      ensure
        StandardId::Events.unsubscribe(subscription)
      end
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

          instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).to be_verified
        end
      end

      context "with email_verified: 'true' (string)" do
        it "verifies the email identifier" do
          info = { email: email, email_verified: "true" }.with_indifferent_access

          instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).to be_verified
        end
      end

      context "with email_verified: false" do
        it "does not verify the email identifier" do
          info = { email: email, email_verified: false }.with_indifferent_access

          instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).not_to be_verified
        end
      end

      context "with email_verified: 'false' (string)" do
        it "does not verify the email identifier" do
          info = { email: email, email_verified: "false" }.with_indifferent_access

          instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).not_to be_verified
        end
      end

      context "with email_verified omitted" do
        it "does not verify the email identifier" do
          info = { email: email }.with_indifferent_access

          instance.send(:find_or_create_account_from_social, info)
          identifier = StandardId::EmailIdentifier.find_by(value: email)

          expect(identifier).not_to be_verified
        end
      end

      it "stores the provider name on the created identifier" do
        info = { email: email, email_verified: true }.with_indifferent_access

        instance.send(:find_or_create_account_from_social, info)
        identifier = StandardId::EmailIdentifier.find_by(value: email)

        expect(identifier.provider).to eq("google")
      end
    end

    context "when linking to an existing account" do
      let!(:existing_account) { Account.create!(email: email, name: "Victim") }

      context "with strict link strategy (default)" do
        around do |example|
          original = StandardId.config.social.link_strategy
          StandardId.config.social.link_strategy = :strict
          example.run
        ensure
          StandardId.config.social.link_strategy = original
        end

        context "when the identifier was created by a DIFFERENT social provider" do
          before do
            StandardId::EmailIdentifier.create!(account: existing_account, value: email, provider: "apple")
          end

          it "blocks the link and raises SocialLinkError" do
            info = { email: email, email_verified: true }.with_indifferent_access

            expect {
              instance.send(:find_or_create_account_from_social, info)
            }.to raise_error(StandardId::SocialLinkError)
          end

          it "includes the email and provider in the error" do
            info = { email: email, email_verified: true }.with_indifferent_access

            expect {
              instance.send(:find_or_create_account_from_social, info)
            }.to raise_error(StandardId::SocialLinkError) { |error|
              expect(error.email).to eq(email)
              expect(error.provider_name).to eq("google")
              expect(error.message).to include("already associated with an account")
            }
          end

          it "emits a SOCIAL_LINK_BLOCKED event" do
            info = { email: email, email_verified: true }.with_indifferent_access
            event_received = nil
            subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_LINK_BLOCKED) do |event|
              event_received = event
            end

            begin
              expect {
                instance.send(:find_or_create_account_from_social, info)
              }.to raise_error(StandardId::SocialLinkError)

              expect(event_received).to be_present
              expect(event_received[:email]).to eq(email)
              expect(event_received[:provider]).to eq(provider)
              expect(event_received[:account]).to eq(existing_account)
            ensure
              StandardId::Events.unsubscribe(subscription)
            end
          end
        end

        context "when the identifier has nil provider (pre-migration data)" do
          before do
            StandardId::EmailIdentifier.create!(account: existing_account, value: email)
          end

          it "allows the link because nil provider predates provider tracking" do
            info = { email: email, email_verified: true }.with_indifferent_access

            result = instance.send(:find_or_create_account_from_social, info)
            expect(result).to eq(existing_account)
          end

          it "backfills the provider on re-login" do
            info = { email: email, email_verified: true }.with_indifferent_access

            instance.send(:find_or_create_account_from_social, info)
            identifier = StandardId::EmailIdentifier.find_by(value: email)

            expect(identifier.provider).to eq("google")
          end
        end

        context "when the identifier was created by the SAME social provider" do
          before do
            StandardId::EmailIdentifier.create!(account: existing_account, value: email, provider: "google")
          end

          it "allows the link and returns the account" do
            info = { email: email, email_verified: true }.with_indifferent_access

            result = instance.send(:find_or_create_account_from_social, info)
            expect(result).to eq(existing_account)
          end
        end

        context "when the account has another identifier from the same provider" do
          before do
            # The email identifier was created via a different provider (e.g. Apple)
            StandardId::EmailIdentifier.create!(account: existing_account, value: email, provider: "apple")
            # But the account also has another identifier linked via Google
            other_email = "other-#{SecureRandom.hex(4)}@example.com"
            StandardId::EmailIdentifier.create!(account: existing_account, value: other_email, provider: "google")
          end

          it "allows the link because the account is already connected to this provider" do
            info = { email: email, email_verified: true }.with_indifferent_access

            result = instance.send(:find_or_create_account_from_social, info)
            expect(result).to eq(existing_account)
          end
        end
      end

      context "with invalid link_strategy config" do
        around do |example|
          original = StandardId.config.social.link_strategy
          StandardId.config.social.link_strategy = :bogus
          example.run
        ensure
          StandardId.config.social.link_strategy = original
        end

        it "raises ArgumentError" do
          StandardId::EmailIdentifier.create!(account: existing_account, value: email, provider: "apple")
          info = { email: email, email_verified: true }.with_indifferent_access

          expect {
            instance.send(:find_or_create_account_from_social, info)
          }.to raise_error(ArgumentError, /Invalid social.link_strategy/)
        end
      end

      context "with trust_provider link strategy" do
        around do |example|
          original = StandardId.config.social.link_strategy
          StandardId.config.social.link_strategy = :trust_provider
          example.run
        ensure
          StandardId.config.social.link_strategy = original
        end

        context "when the identifier was NOT created via social login (account takeover scenario)" do
          before do
            StandardId::EmailIdentifier.create!(account: existing_account, value: email)
          end

          it "allows the link (legacy behavior)" do
            info = { email: email, email_verified: true }.with_indifferent_access

            result = instance.send(:find_or_create_account_from_social, info)
            expect(result).to eq(existing_account)
          end
        end
      end
    end
  end
end
