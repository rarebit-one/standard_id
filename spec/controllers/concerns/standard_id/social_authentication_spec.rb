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

  describe "#find_or_create_account_from_social subject matching and verified linking (L1-01)" do
    let(:email) { "sub-#{SecureRandom.hex(4)}@example.com" }
    let(:provider_name) { "google" }
    let(:provider) { double("Provider", provider_name: provider_name) }
    let(:sub) { "sub-#{SecureRandom.hex(6)}" }

    before do
      allow(instance).to receive(:provider).and_return(provider)
      allow(instance).to receive(:resolve_account_attributes).and_return({ name: "Test", email: email })
    end

    def login(info)
      instance.send(:find_or_create_account_from_social, info.with_indifferent_access)
    end

    def with_link_strategy(strategy)
      original = StandardId.config.social.link_strategy
      StandardId.config.social.link_strategy = strategy
      yield
    ensure
      StandardId.config.social.link_strategy = original
    end

    def capture_link_blocked
      received = nil
      subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_LINK_BLOCKED) { |event| received = event }
      yield
      received
    ensure
      StandardId::Events.unsubscribe(subscription)
    end

    context "when (provider, sub) matches a stored social identity" do
      let!(:account) { Account.create!(email: email, name: "Owner") }
      let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: email, provider: provider_name) }

      before do
        StandardId::SocialIdentity.create!(account: account, identifier: identifier, provider: provider_name, subject: sub)
      end

      it "returns that account even when the provider now reports a different, unverified email" do
        result = login(email: "renamed-#{SecureRandom.hex(4)}@example.com", sub: sub, email_verified: false)

        expect(result).to eq(account)
        expect(StandardId::EmailIdentifier.where(account: account).count).to eq(1)
      end

      it "returns that account without requiring email_verified" do
        expect(login(email: email, sub: sub)).to eq(account)
      end

      it "does not match the same sub from a different provider" do
        apple = double("Provider", provider_name: "apple")
        allow(instance).to receive(:provider).and_return(apple)

        expect {
          login(email: email, sub: sub, email_verified: true)
        }.to raise_error(StandardId::SocialLinkError) { |error| expect(error.reason).to eq(:link_required) }
      end
    end

    context "when linking to an existing email identifier with no subject match" do
      let!(:account) { Account.create!(email: email, name: "Owner") }
      let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: email) }

      it "links on a verified email and stores the sub" do
        result = login(email: email, sub: sub, email_verified: true)

        expect(result).to eq(account)
        social_identity = StandardId::SocialIdentity.find_by(provider: provider_name, subject: sub)
        expect(social_identity).to have_attributes(account_id: account.id, identifier_id: identifier.id)
      end

      it "matches on the stored sub at the next login" do
        login(email: email, sub: sub, email_verified: true)

        expect(login(email: email, sub: sub, email_verified: false)).to eq(account)
      end

      it "accepts Apple's string \"true\" as verified" do
        apple = double("Provider", provider_name: "apple")
        allow(instance).to receive(:provider).and_return(apple)

        expect(login(email: email, sub: sub, email_verified: "true")).to eq(account)
        expect(StandardId::SocialIdentity.find_by(provider: "apple", subject: sub)&.account_id).to eq(account.id)
      end

      it "accepts Google v2 userinfo's verified_email when email_verified is absent" do
        expect(login(email: email, sub: sub, verified_email: true)).to eq(account)
      end

      [false, "false", nil, "", "yes", "1"].each do |value|
        it "refuses the link when email_verified is #{value.inspect}" do
          event = capture_link_blocked do
            expect {
              login(email: email, sub: sub, email_verified: value)
            }.to raise_error(StandardId::SocialLinkError) { |error| expect(error.reason).to eq(:email_unverified) }
          end

          expect(event[:reason]).to eq(:email_unverified)
          expect(StandardId::SocialIdentity.where(subject: sub)).to be_empty
          expect(Account.where(email: email).count).to eq(1)
        end
      end

      it "refuses the link when email_verified is omitted" do
        expect {
          login(email: email, sub: sub)
        }.to raise_error(StandardId::SocialLinkError)
      end

      it "refuses an unverified link under :trust_provider too" do
        with_link_strategy(:trust_provider) do
          expect {
            login(email: email, sub: sub, email_verified: false)
          }.to raise_error(StandardId::SocialLinkError) { |error| expect(error.reason).to eq(:email_unverified) }
        end
      end

      it "still links a verified email under :trust_provider and stores the sub" do
        with_link_strategy(:trust_provider) do
          expect(login(email: email, sub: sub, email_verified: true)).to eq(account)
        end
        expect(StandardId::SocialIdentity.find_by(provider: provider_name, subject: sub)).to be_present
      end

      it "links without storing anything when the provider reports no sub" do
        expect(login(email: email, email_verified: true)).to eq(account)
        expect(StandardId::SocialIdentity.where(account_id: account.id)).to be_empty
      end
    end

    context "when the email identifier is already linked to a different sub from the same provider" do
      let!(:account) { Account.create!(email: email, name: "Owner") }
      let!(:identifier) { StandardId::EmailIdentifier.create!(account: account, value: email, provider: provider_name) }

      before do
        StandardId::SocialIdentity.create!(account: account, identifier: identifier, provider: provider_name, subject: "original-sub")
      end

      it "refuses the link as a possible takeover, even on a verified email" do
        event = capture_link_blocked do
          expect {
            login(email: email, sub: sub, email_verified: true)
          }.to raise_error(StandardId::SocialLinkError) { |error| expect(error.reason).to eq(:subject_mismatch) }
        end

        expect(event[:reason]).to eq(:subject_mismatch)
        expect(StandardId::SocialIdentity.where(subject: sub)).to be_empty
      end

      it "refuses it under :trust_provider too" do
        with_link_strategy(:trust_provider) do
          expect {
            login(email: email, sub: sub, email_verified: true)
          }.to raise_error(StandardId::SocialLinkError) { |error| expect(error.reason).to eq(:subject_mismatch) }
        end
      end
    end

    context "when no account exists" do
      it "creates the account as before and stores the sub" do
        account = nil
        expect {
          account = login(email: email, sub: sub, email_verified: false)
        }.to change(Account, :count).by(1)

        identifier = StandardId::EmailIdentifier.find_by(value: email)
        expect(identifier).not_to be_verified
        expect(identifier.provider).to eq(provider_name)
        expect(StandardId::SocialIdentity.find_by(provider: provider_name, subject: sub)).to have_attributes(
          account_id: account.id, identifier_id: identifier.id
        )
      end

      it "creates the account without a social identity when the provider reports no sub" do
        expect { login(email: email, email_verified: true) }.to change(Account, :count).by(1)
        expect(StandardId::SocialIdentity.count).to eq(0)
      end
    end

    context "when the host has not run the social identities migration" do
      let!(:account) { Account.create!(email: email, name: "Owner") }

      before do
        StandardId::EmailIdentifier.create!(account: account, value: email)
        allow(StandardId::SocialIdentity).to receive(:available?).and_return(false)
      end

      it "still links a verified email, without subject matching" do
        expect(login(email: email, sub: sub, email_verified: true)).to eq(account)
      end

      it "still refuses an unverified email" do
        expect {
          login(email: email, sub: sub, email_verified: false)
        }.to raise_error(StandardId::SocialLinkError) { |error| expect(error.reason).to eq(:email_unverified) }
      end
    end

    context "when the identifier is deleted" do
      it "cascades its social identities" do
        account = login(email: email, sub: sub, email_verified: true)
        StandardId::EmailIdentifier.where(account: account).delete_all

        expect(StandardId::SocialIdentity.where(subject: sub)).to be_empty
      end
    end
  end

  describe "#emit_social_auth_failed" do
    let(:provider) { double("Provider", provider_name: "google") }
    let(:error) { StandardId::OAuthError.new("Connection refused") }

    before do
      allow(instance).to receive(:provider).and_return(provider)
    end

    it "publishes SOCIAL_AUTH_FAILED with provider, error, error_class, and account" do
      event_received = nil
      subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) do |event|
        event_received = event
      end

      begin
        instance.send(:emit_social_auth_failed, error, account: account)

        expect(event_received).to be_present
        expect(event_received[:provider]).to eq("google")
        expect(event_received[:error]).to eq("Connection refused")
        expect(event_received[:error_class]).to eq("StandardId::OAuthError")
        expect(event_received[:account]).to eq(account)
      ensure
        StandardId::Events.unsubscribe(subscription)
      end
    end

    it "emits with account: nil when no account was resolved before the failure" do
      event_received = nil
      subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) do |event|
        event_received = event
      end

      begin
        instance.send(:emit_social_auth_failed, error)

        expect(event_received).to be_present
        expect(event_received[:account]).to be_nil
      ensure
        StandardId::Events.unsubscribe(subscription)
      end
    end

    it "emits with provider: nil when provider resolution failed" do
      allow(instance).to receive(:provider).and_return(nil)

      event_received = nil
      subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) do |event|
        event_received = event
      end

      begin
        instance.send(:emit_social_auth_failed, error)

        expect(event_received).to be_present
        expect(event_received[:provider]).to be_nil
        expect(event_received[:error]).to eq("Connection refused")
      ensure
        StandardId::Events.unsubscribe(subscription)
      end
    end
  end
end
