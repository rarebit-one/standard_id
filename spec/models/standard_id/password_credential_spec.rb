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

    describe "#rehash_password" do
      let(:password) { "Password1!" }
      let(:old_cost) { BCrypt::Engine::MIN_COST + 1 }
      let!(:credential) do
        described_class.create!(login: "user@example.com", password: password).tap do |c|
          StandardId::Credential.create!(credentialable: c, identifier: identifier)
          c.update_column(:password_digest, BCrypt::Password.create(password, cost: old_cost))
        end
      end

      def stored_cost
        BCrypt::Password.new(described_class.find(credential.id).password_digest).cost
      end

      it "re-hashes a digest made at another cost, keeping the password" do
        expect(credential.rehash_password(password)).to be(true)

        expect(stored_cost).to eq(described_class.password_cost)
        expect(described_class.find(credential.id).authenticate(password)).to be_truthy
        expect(credential.password_digest).to eq(described_class.find(credential.id).password_digest)
        expect(credential).not_to be_changed
      end

      it "does nothing to a digest already at the current cost" do
        expect(credential.rehash_password(password)).to be(true)

        expect { expect(credential.rehash_password(password)).to be(false) }
          .not_to change { described_class.find(credential.id).password_digest }
      end

      it "follows BCrypt::Engine.cost when min_cost is off" do
        min_cost = ActiveModel::SecurePassword.min_cost
        ActiveModel::SecurePassword.min_cost = false
        BCrypt::Engine.cost = old_cost
        expect(credential.rehash_password(password)).to be(false)

        BCrypt::Engine.cost = old_cost + 1
        expect(credential.rehash_password(password)).to be(true)
        expect(stored_cost).to eq(old_cost + 1)
      ensure
        ActiveModel::SecurePassword.min_cost = min_cost
        BCrypt::Engine.cost = BCrypt::Engine::MIN_COST
      end

      it "leaves the row alone when its digest is no longer the one that authenticated" do
        authenticated_digest = credential.password_digest
        described_class.find(credential.id).update!(password: "Res3t-elsewhere!")

        expect(credential.rehash_password(password, authenticated_digest)).to be(false)
        expect(described_class.find(credential.id).authenticate("Res3t-elsewhere!")).to be_truthy
      end

      it "keeps the record's loaded associations" do
        loaded = described_class.includes(credential: { identifier: :account }).find(credential.id)
        loaded.rehash_password(password)

        expect(loaded.association(:credential)).to be_loaded
        expect(loaded.credential.association(:identifier)).to be_loaded
      end

      it "publishes CREDENTIAL_PASSWORD_REHASHED once the enclosing transaction commits" do
        events = []
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) { |e| events << e.payload }
        ActiveRecord::Base.transaction do
          credential.rehash_password(password)
          expect(events).to be_empty
        end

        expect(events.size).to eq(1)
        expect(events.first).to include(credential: credential, account: account, previous_cost: old_cost, cost: described_class.password_cost)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      it "publishes nothing when the enclosing transaction rolls back" do
        events = []
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) { |e| events << e }
        ActiveRecord::Base.transaction do
          credential.rehash_password(password)
          raise ActiveRecord::Rollback
        end

        expect(events).to be_empty
        expect(stored_cost).to eq(old_cost)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      it "does nothing when c.password.rehash_on_login is false" do
        StandardId.config.password.rehash_on_login = false

        expect(credential.rehash_password(password)).to be(false)
        expect(stored_cost).to eq(old_cost)
      end

      it "reports and returns false instead of raising when the write fails" do
        allow(described_class).to receive(:transaction).and_raise(ActiveRecord::StatementInvalid, "boom")
        allow(Rails.error).to receive(:report)
        old_digest = credential.password_digest

        expect(credential.rehash_password(password)).to be(false)
        expect(credential.password_digest).to eq(old_digest)
        expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::StatementInvalid), handled: true, source: "standard_id")
      end

      it "still succeeds when a CREDENTIAL_PASSWORD_REHASHED subscriber raises" do
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) { raise "boom" }
        allow(Rails.error).to receive(:report)

        expect(credential.rehash_password(password)).to be(true)
        expect(stored_cost).to eq(described_class.password_cost)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      it "voids remember-me and reset tokens minted from the old digest" do
        remember = credential.generate_token_for(:remember_me)
        reset = credential.generate_token_for(:password_reset)
        credential.rehash_password(password)

        expect(described_class.find_by_token_for(:remember_me, remember)).to be_nil
        expect(described_class.find_by_token_for(:password_reset, reset)).to be_nil
      end
    end

    describe "CREDENTIAL_PASSWORD_CHANGED" do
      let!(:credential) do
        described_class.create!(login: "user@example.com", password: "Password1!").tap do |c|
          StandardId::Credential.create!(credentialable: c, identifier: identifier)
        end
      end

      def changed_events
        events = []
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_CHANGED) { |e| events << e.payload }
        yield
        events
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      it "publishes after a new password is saved, with reason :changed" do
        events = changed_events { credential.update!(password: "NewPass1!abc") }

        expect(events.size).to eq(1)
        expect(events.first).to include(credential: credential, account: account, reason: :changed)
      end

      it "carries the reason a caller set, then forgets it" do
        credential.password_change_reason = :password_reset
        first = changed_events { credential.update!(password: "NewPass1!abc") }
        second = changed_events { credential.update!(password: "An0ther!pass") }

        expect(first.map { |e| e[:reason] }).to eq([:password_reset])
        expect(second.map { |e| e[:reason] }).to eq([:changed])
      end

      it "publishes nothing on create, nor on a later save that leaves the password alone" do
        events = changed_events do
          fresh = described_class.create!(login: "fresh@example.com", password: "Password1!")
          fresh.update!(login: "renamed@example.com")
        end

        expect(events).to be_empty
      end

      it "publishes nothing when only the digest is written (a rehash of the same password)" do
        events = changed_events do
          credential.update!(password_digest: BCrypt::Password.create("Password1!", cost: BCrypt::Engine::MIN_COST + 1))
          credential.update_column(:password_digest, BCrypt::Password.create("Password1!"))
        end

        expect(events).to be_empty
      end

      it "is not published by a rehash on login, which keeps the same password" do
        credential.update_column(:password_digest, BCrypt::Password.create("Password1!", cost: BCrypt::Engine::MIN_COST + 1))
        events = changed_events { expect(credential.rehash_password("Password1!")).to be(true) }

        expect(events).to be_empty
      end

      it "publishes nothing for an empty assignment, which leaves the password as it was" do
        events = changed_events { credential.update!(password: "") }

        expect(events).to be_empty
      end

      it "waits for the commit and publishes nothing on rollback" do
        events = changed_events do
          ActiveRecord::Base.transaction do
            credential.update!(password: "NewPass1!abc")
            raise ActiveRecord::Rollback
          end
        end

        expect(events).to be_empty
      end

      it "still publishes after commit when a savepoint inside the transaction rolls back" do
        events = changed_events do
          ActiveRecord::Base.transaction do
            credential.update!(password: "NewPass1!abc")
            ActiveRecord::Base.transaction(requires_new: true) do
              credential.update!(login: "renamed@example.com")
              raise ActiveRecord::Rollback
            end
          end
        end

        expect(events.size).to eq(1)
        expect(described_class.find(credential.id).authenticate("NewPass1!abc")).to be_truthy
      end

      it "publishes nothing for a later commit that did not write the assigned password" do
        events = changed_events do
          ActiveRecord::Base.transaction do
            credential.update!(password: "NewPass1!abc")
            raise ActiveRecord::Rollback
          end
          # Inside the example's own transaction the rollback above is a
          # savepoint, which leaves the record clean, so this save writes no
          # digest. The record still holds the assigned one.
          credential.save!
        end

        expect(events).to be_empty
        expect(described_class.find(credential.id).authenticate("Password1!")).to be_truthy
      end

      it "carries credential_id, which survives events.publish_records = false" do
        StandardId.config.events.publish_records = false
        StandardId.config.events.publish_record_identifiers = false
        events = changed_events { credential.update!(password: "NewPass1!abc") }

        expect(events.size).to eq(1)
        expect(events.first).not_to have_key(:credential)
        expect(events.first[:credential_id]).to eq(credential.id)
      end

      it "publishes once per transaction" do
        events = changed_events do
          ActiveRecord::Base.transaction do
            credential.update!(password: "NewPass1!abc")
            credential.update!(login: "renamed@example.com")
          end
        end

        expect(events.size).to eq(1)
      end

      it "lets a subscriber walk the credential chain under strict loading" do
        accounts = []
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_CHANGED) do |e|
          accounts << e[:credential].credential.identifier.account
        end
        described_class.find(credential.id).update!(password: "NewPass1!abc")

        expect(accounts).to eq([account])
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      it "still saves, and reports, when a subscriber raises" do
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_CHANGED) { raise "boom" }
        allow(Rails.error).to receive(:report)

        expect { credential.update!(password: "NewPass1!abc") }.not_to raise_error
        expect(described_class.find(credential.id).authenticate("NewPass1!abc")).to be_truthy
        expect(Rails.error).to have_received(:report).with(an_instance_of(RuntimeError), handled: true, source: "standard_id")
      ensure
        StandardId::Events.unsubscribe(sub)
      end
    end

    # A real (top-level) rollback restores the record's pending changes, so a
    # retried save! writes the new digest. That needs a transaction of its
    # own, not the example's savepoint.
    describe "CREDENTIAL_PASSWORD_CHANGED after a rolled-back save is retried" do
      self.use_transactional_tests = false

      let(:login) { "retry-#{SecureRandom.hex(4)}@example.com" }

      after { described_class.where(login: login).delete_all }

      it "publishes once the retry commits the new password" do
        credential = described_class.create!(login: login, password: "Password1!")
        credential.password_change_reason = :password_reset
        events = []
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_CHANGED) { |e| events << e.payload }

        ActiveRecord::Base.transaction do
          credential.update!(password: "NewPass1!abc")
          raise ActiveRecord::Rollback
        end
        expect(events).to be_empty

        credential.save!

        expect(described_class.find(credential.id).authenticate("NewPass1!abc")).to be_truthy
        expect(events.map { |e| e[:reason] }).to eq([:password_reset])
      ensure
        StandardId::Events.unsubscribe(sub)
      end
    end
  end
end
