require "rails_helper"

RSpec.describe StandardId::AccountAssociations, type: :model do
  let(:account) { Account.create!(name: "Test User", email: "account@example.com") }

  describe "associations" do
    it { expect(account).to have_many(:identifiers) }
    it { expect(account).to have_many(:credentials).through(:identifiers) }
    it { expect(account).to have_many(:sessions) }
    it { expect(account).to have_many(:client_applications) }
  end

  describe ".find_or_create_by_verified_email!" do
    let(:email) { "test@example.com" }

    context "when an account with a verified email identifier already exists" do
      let!(:existing_account) do
        Account.create!(name: "Test", email: email,
          identifiers_attributes: [{ type: "StandardId::EmailIdentifier", value: email, verified_at: Time.current }])
      end

      it "returns the existing account" do
        expect(Account.find_or_create_by_verified_email!(email, name: "Other")).to eq(existing_account)
      end

      it "does not create a new account" do
        expect { Account.find_or_create_by_verified_email!(email, name: "Other") }.not_to change(Account, :count)
      end
    end

    context "when no account exists for the email" do
      it "creates a new account with verified email identifier" do
        account = Account.find_or_create_by_verified_email!(email, name: "New User")
        expect(account).to be_persisted
        identifier = account.identifiers.find_by(type: "StandardId::EmailIdentifier")
        expect(identifier.value).to eq(email)
        expect(identifier.verified_at).to be_present
      end

      it "passes additional attributes to the account" do
        account = Account.find_or_create_by_verified_email!(email, name: "Custom Name")
        expect(account.name).to eq("Custom Name")
      end

      it "publishes ACCOUNT_CREATING and ACCOUNT_CREATED events" do
        events = []
        sub1 = StandardId::Events.subscribe(StandardId::Events::ACCOUNT_CREATING) { |e| events << e }
        sub2 = StandardId::Events.subscribe(StandardId::Events::ACCOUNT_CREATED) { |e| events << e }
        Account.find_or_create_by_verified_email!(email, name: "Test")
        expect(events.map(&:name)).to contain_exactly(
          "standard_id.#{StandardId::Events::ACCOUNT_CREATING}",
          "standard_id.#{StandardId::Events::ACCOUNT_CREATED}"
        )
      ensure
        StandardId::Events.unsubscribe(sub1, sub2)
      end
    end

    context "race condition (RecordNotUnique)" do
      let!(:existing_account) do
        Account.create!(name: "Existing", email: email,
          identifiers_attributes: [{ type: "StandardId::EmailIdentifier", value: email, verified_at: Time.current }])
      end

      it "returns the existing account when create! hits a unique constraint" do
        call_count = 0
        allow(Account).to receive(:create!).and_wrap_original do |method, *args, **kwargs|
          call_count += 1
          raise ActiveRecord::RecordNotUnique if call_count == 1

          method.call(*args, **kwargs)
        end

        result = Account.find_or_create_by_verified_email!(email, name: "Racer")
        expect(result).to eq(existing_account)
      end
    end

    context "nil/blank email" do
      it "raises ArgumentError for nil" do
        expect { Account.find_or_create_by_verified_email!(nil, name: "T") }.to raise_error(ArgumentError)
      end

      it "raises ArgumentError for blank string" do
        expect { Account.find_or_create_by_verified_email!("  ", name: "T") }.to raise_error(ArgumentError)
      end
    end

    context "email normalization" do
      it "strips and downcases" do
        account = Account.find_or_create_by_verified_email!("  Test@Example.COM  ", name: "Test")
        expect(account.identifiers.first.value).to eq("test@example.com")
      end

      it "finds existing accounts regardless of case" do
        Account.find_or_create_by_verified_email!("test@example.com", name: "Test")
        expect { Account.find_or_create_by_verified_email!("TEST@EXAMPLE.COM", name: "X") }.not_to change(Account, :count)
      end
    end
  end

  describe "typed identifier accessors" do
    let(:email) { "typed-#{SecureRandom.hex(4)}@example.com" }
    let(:phone) { "+1415555#{rand(1000..9999)}" }
    let(:username) { "user_#{SecureRandom.hex(4)}" }

    let!(:account_with_all_identifiers) do
      Account.create!(
        name: "All Types",
        email: email,
        identifiers_attributes: [
          { type: "StandardId::EmailIdentifier", value: email },
          { type: "StandardId::PhoneNumberIdentifier", value: phone },
          { type: "StandardId::UsernameIdentifier", value: username }
        ]
      )
    end

    describe "#email_identifier" do
      it "returns the EmailIdentifier for the account" do
        result = account_with_all_identifiers.email_identifier
        expect(result).to be_a(StandardId::EmailIdentifier)
        expect(result.value).to eq(email)
      end

      it "returns nil when no email identifier exists" do
        bare = Account.create!(name: "No Email Ident", email: "bare-#{SecureRandom.hex(4)}@example.com")
        expect(bare.email_identifier).to be_nil
      end

      it "does not issue a query when the identifiers association is already loaded" do
        account = Account.includes(:identifiers).find(account_with_all_identifiers.id)
        expect(account.association(:identifiers)).to be_loaded

        queries = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          next if payload[:name].to_s.start_with?("SCHEMA") || payload[:name].to_s.start_with?("TRANSACTION")
          queries << payload[:sql]
        end

        begin
          result = account.email_identifier
          expect(result).to be_a(StandardId::EmailIdentifier)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        expect(queries).to be_empty, "expected no queries when identifiers loaded, got: #{queries.inspect}"
      end

      it "issues a scoped query when identifiers is not loaded" do
        account = Account.find(account_with_all_identifiers.id)
        expect(account.association(:identifiers)).not_to be_loaded

        result = account.email_identifier
        expect(result).to be_a(StandardId::EmailIdentifier)
        # A query was issued, but the association should not be fully loaded
        # because we used a scoped where(type: ...).first.
        expect(account.association(:identifiers)).not_to be_loaded
      end
    end

    describe "#phone_number_identifier" do
      it "returns the PhoneNumberIdentifier for the account" do
        result = account_with_all_identifiers.phone_number_identifier
        expect(result).to be_a(StandardId::PhoneNumberIdentifier)
        expect(result.value).to eq(phone)
      end
    end

    describe "#username_identifier" do
      it "returns the UsernameIdentifier for the account" do
        result = account_with_all_identifiers.username_identifier
        expect(result).to be_a(StandardId::UsernameIdentifier)
        expect(result.value).to eq(username)
      end
    end
  end
end
