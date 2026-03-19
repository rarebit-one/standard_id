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
        allow(StandardId::EmailIdentifier).to receive(:find_by).and_wrap_original do |method, **args|
          call_count += 1
          call_count == 1 ? nil : method.call(**args)
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
end
