require "rails_helper"

module StandardId
  RSpec.describe EmailIdentifier, type: :model do
    let(:account) { Account.create!(name: "Test User", email: "account@example.com") }

    it { is_expected.to be_a(Identifier) }
    it { is_expected.to belong_to(:account) }

    describe "validations" do
      it "validates email format" do
        subject = EmailIdentifier.new(value: "invalid-email", account: account)
        expect(subject).not_to be_valid
        expect(subject.errors[:value]).to be_present

        subject.value = "user@example.com"
        subject.valid?
        expect(subject.errors[:value]).to be_empty
      end

      # `URI::MailTo::EMAIL_REGEXP` accepts all of these; Postmark rejects them
      # at send time, which is far too late to be actionable.
      [
        "jas.on..me.eker.86@gmail.com",
        "a..b@example.com",
        ".leading@example.com",
        "trailing.@example.com"
      ].each do |bad|
        it "rejects #{bad.inspect}, which is not a valid dot-atom local part" do
          identifier = EmailIdentifier.new(value: bad, account: account)
          expect(identifier).not_to be_valid
          expect(identifier.errors[:value]).to be_present
        end
      end

      [
        "user@example.com",
        "first.last@example.com",
        "a.b.c.d@sub.example.co.uk",
        "user+tag@example.com",
        "user_name-1@example.com"
      ].each do |good|
        it "accepts #{good.inspect}" do
          identifier = EmailIdentifier.new(value: good, account: account)
          identifier.valid?
          expect(identifier.errors[:value]).to be_empty
        end
      end

      # Tightening a rule must not strand accounts created under the looser one.
      it "leaves an existing record with a grandfathered address saveable" do
        identifier = EmailIdentifier.new(value: "old.address@example.com", account: account)
        identifier.save!
        identifier.update_column(:value, "grand..fathered@example.com")
        identifier.reload

        expect(identifier.verified_at).to be_nil
        expect { identifier.update!(verified_at: Time.current) }.not_to raise_error
      end

      it "still rejects the bad format when the address itself is edited" do
        identifier = EmailIdentifier.new(value: "old.address@example.com", account: account)
        identifier.save!

        identifier.value = "now..invalid@example.com"

        expect(identifier).not_to be_valid
        expect(identifier.errors[:value]).to be_present
      end

      describe "registered TLD" do
        %w[jaryl@rarebit.ome user@example.con user@example.invalidtld].each do |bad|
          it "rejects #{bad.inspect}" do
            identifier = EmailIdentifier.new(value: bad, account: account)

            expect(identifier).not_to be_valid
            expect(identifier.errors.details[:value]).to include(error: :unregistered_tld)
          end
        end

        %w[user@rarebit.one user@example.sg user@example.app user@example.xn--p1ai].each do |good|
          it "accepts #{good.inspect}" do
            identifier = EmailIdentifier.new(value: good, account: account)
            identifier.valid?
            expect(identifier.errors[:value]).to be_empty
          end
        end

        it "accepts a special-use TLD used on purpose for a synthetic account" do
          expect(EmailIdentifier.new(value: "agent+1@agents.app.invalid", account: account)).to be_valid
        end

        it "normalizes before checking, so case and whitespace don't matter" do
          identifier = EmailIdentifier.new(value: "  User@Example.CO.UK ", account: account)

          expect(identifier).to be_valid
          expect(identifier.value).to eq("user@example.co.uk")
        end

        it "reports only the format error for an address that fails both" do
          identifier = EmailIdentifier.new(value: "a..b@rarebit.ome", account: account)

          expect(identifier).not_to be_valid
          expect(identifier.errors.details[:value].pluck(:error)).to eq([:invalid])
        end

        it "leaves an existing row on an unregistered TLD saveable" do
          identifier = EmailIdentifier.create!(value: "old.address@example.com", account: account)
          identifier.update_column(:value, "grandfathered@rarebit.ome")
          identifier.reload

          expect { identifier.update!(verified_at: Time.current) }.not_to raise_error
        end

        it "checks the address again when it is edited" do
          identifier = EmailIdentifier.create!(value: "old.address@example.com", account: account)

          identifier.value = "now@rarebit.ome"

          expect(identifier).not_to be_valid
          expect(identifier.errors.details[:value]).to include(error: :unregistered_tld)
        end

        it "is skipped when email.require_registered_tld is off" do
          allow(StandardId.config.email).to receive(:require_registered_tld).and_return(false)

          expect(EmailIdentifier.new(value: "jaryl@rarebit.ome", account: account)).to be_valid
        end
      end
    end
  end
end
