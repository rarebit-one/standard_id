require "rails_helper"

# c.password.pepper / previous_peppers / accept_unpeppered_passwords on
# PasswordCredential: how digests are written, verified and moved to the
# current pepper by #rehash_password. See StandardId::PasswordPepper.
module StandardId
  RSpec.describe PasswordCredential, type: :model do
    let(:account) { Account.create!(name: "Pepper User", email: "pepper@example.com") }
    let(:identifier) { EmailIdentifier.create!(account: account, value: "pepper@example.com") }
    let(:password) { "Sup3r-secret!" }
    let(:pepper) { "current-pepper-#{"x" * 32}" }
    let(:old_pepper) { "previous-pepper-#{"y" * 32}" }

    def create_credential
      described_class.create!(login: "pepper@example.com", password: password).tap do |c|
        Credential.create!(credentialable: c, identifier: identifier)
      end
    end

    def stored(credential)
      described_class.find(credential.id)
    end

    def digest_under(pepper_value)
      BCrypt::Password.create(PasswordPepper.apply(password, pepper_value), cost: described_class.password_cost)
    end

    def made_under?(credential, pepper_value)
      BCrypt::Password.new(stored(credential).password_digest).is_password?(PasswordPepper.apply(password, pepper_value))
    end

    def events_for(name)
      events = []
      sub = StandardId::Events.subscribe(name) { |e| events << e.payload }
      yield
      events
    ensure
      StandardId::Events.unsubscribe(sub)
    end

    describe "with no pepper (the default)" do
      it "stores has_secure_password's digest of the bare password" do
        credential = create_credential

        expect(made_under?(credential, "")).to be(true)
        expect(stored(credential).authenticate(password)).to be_truthy
        expect(stored(credential).authenticate("Wr0ng-password!")).to be(false)
      end

      it "does not rehash, nor pay for another comparison, when the cost is current" do
        credential = stored(create_credential)
        credential.authenticate(password)
        allow(BCrypt::Engine).to receive(:hash_secret).and_call_original

        expect(credential.rehash_password(password)).to be(false)
        expect(BCrypt::Engine).not_to have_received(:hash_secret)
      end
    end

    describe "with a pepper" do
      before { StandardId.config.password.pepper = pepper }

      it "stores bcrypt(HMAC-SHA256(pepper, password)), not a digest of the bare password" do
        credential = create_credential

        expect(made_under?(credential, pepper)).to be(true)
        expect(made_under?(credential, "")).to be(false)
      end

      it "peppers a password that is only whitespace, as has_secure_password hashes it" do
        credential = described_class.new(login: "blank@example.com")
        credential.password = "   "

        expect(BCrypt::Password.new(credential.password_digest).is_password?(PasswordPepper.apply("   ", pepper))).to be(true)
      end

      it "clears the digest on nil and ignores an empty assignment" do
        credential = described_class.new(login: "nil@example.com", password: password)
        digest = credential.password_digest
        credential.password = ""
        expect(credential.password_digest).to eq(digest)

        credential.password = nil
        expect(credential.password_digest).to be_nil
      end

      it "authenticates the right password and refuses a wrong one" do
        credential = stored(create_credential)

        expect(credential.authenticate(password)).to eq(credential)
        expect(credential.authenticate_password(password)).to eq(credential)
        expect(credential.authenticate("Wr0ng-password!")).to be(false)
        expect(credential.authenticate("")).to be(false)
      end

      it "refuses every password when the digest is blank" do
        credential = stored(create_credential)
        credential.password_digest = nil

        expect(credential.authenticate(password)).to be(false)
      end

      it "tells apart passwords that differ past bcrypt's 72 bytes, since bcrypt only sees the HMAC" do
        credential = described_class.new(login: "long@example.com", password: "#{"a" * 72}1")

        expect(credential.authenticate("#{"a" * 72}1")).to eq(credential)
        expect(credential.authenticate("#{"a" * 72}2")).to be(false)
      end

      it "does not rehash a digest already under the current pepper" do
        credential = stored(create_credential)
        credential.authenticate(password)

        expect(credential.rehash_password(password)).to be(false)
      end

      describe "a legacy unpeppered digest" do
        let!(:credential) { create_credential.tap { |c| c.update_column(:password_digest, digest_under("")) } }

        it "still authenticates, so turning the pepper on locks nobody out" do
          expect(stored(credential).authenticate(password)).to be_truthy
          expect(stored(credential).authenticate("Wr0ng-password!")).to be(false)
        end

        it "is re-hashed under the current pepper" do
          loaded = stored(credential)
          loaded.authenticate(password)

          expect(loaded.rehash_password(password)).to be(true)
          expect(made_under?(credential, pepper)).to be(true)
          expect(stored(credential).authenticate(password)).to be_truthy
        end

        it "publishes CREDENTIAL_PASSWORD_REHASHED with pepper_changed, and never CREDENTIAL_PASSWORD_CHANGED" do
          loaded = described_class.includes(credential: { identifier: :account }).find(credential.id)
          loaded.authenticate(password)
          changed = []
          rehashed = events_for(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) do
            changed = events_for(StandardId::Events::CREDENTIAL_PASSWORD_CHANGED) { loaded.rehash_password(password) }
          end

          expect(changed).to be_empty
          expect(rehashed.size).to eq(1)
          expect(rehashed.first).to include(account: account, pepper_changed: true, cost: described_class.password_cost)
        end

        it "works out the pepper itself when called without #authenticate" do
          expect(stored(credential).rehash_password(password)).to be(true)
          expect(made_under?(credential, pepper)).to be(true)
        end

        it "does not rehash a password that does not match the digest" do
          expect(stored(credential).rehash_password("Wr0ng-password!")).to be(false)
          expect(made_under?(credential, "")).to be(true)
        end

        it "lets a reset that got there first win (the UPDATE is conditional on the digest)" do
          loaded = stored(credential)
          loaded.authenticate(password)
          seen = loaded.password_digest
          stored(credential).update!(password: "Res3t-elsewhere!")

          expect(loaded.rehash_password(password, seen)).to be(false)
          expect(stored(credential).authenticate("Res3t-elsewhere!")).to be_truthy
        end

        it "voids remember-me and reset tokens minted from the old digest" do
          loaded = stored(credential)
          remember = loaded.generate_token_for(:remember_me)
          reset = loaded.generate_token_for(:password_reset)
          loaded.authenticate(password)
          loaded.rehash_password(password)

          expect(described_class.find_by_token_for(:remember_me, remember)).to be_nil
          expect(described_class.find_by_token_for(:password_reset, reset)).to be_nil
        end

        it "is left alone when c.password.rehash_on_login is false" do
          StandardId.config.password.rehash_on_login = false
          loaded = stored(credential)
          loaded.authenticate(password)

          expect(loaded.rehash_password(password)).to be(false)
          expect(made_under?(credential, "")).to be(true)
        end

        it "is refused once accept_unpeppered_passwords is off" do
          StandardId.config.password.accept_unpeppered_passwords = false

          expect(stored(credential).authenticate(password)).to be(false)
        end
      end

      describe "rotation" do
        let!(:credential) { create_credential.tap { |c| c.update_column(:password_digest, digest_under(old_pepper)) } }

        before { StandardId.config.password.previous_peppers = [old_pepper] }

        it "accepts a digest made under a previous pepper and moves it to the current one" do
          loaded = stored(credential)

          expect(loaded.authenticate(password)).to be_truthy
          expect(loaded.rehash_password(password)).to be(true)
          expect(made_under?(credential, pepper)).to be(true)
        end

        it "refuses a wrong password" do
          expect(stored(credential).authenticate("Wr0ng-password!")).to be(false)
        end

        it "refuses the digest once the previous pepper is dropped" do
          StandardId.config.password.previous_peppers = []

          expect(stored(credential).authenticate(password)).to be(false)
        end
      end

      it "re-hashes at the current cost too when both changed" do
        credential = create_credential
        credential.update_column(:password_digest, BCrypt::Password.create(password, cost: BCrypt::Engine::MIN_COST + 1))
        loaded = stored(credential)
        loaded.authenticate(password)

        expect(loaded.rehash_password(password)).to be(true)
        expect(BCrypt::Password.new(stored(credential).password_digest).cost).to eq(described_class.password_cost)
        expect(made_under?(credential, pepper)).to be(true)
      end
    end

    describe "turning the pepper off (only previous_peppers set)" do
      let!(:credential) do
        StandardId.config.password.pepper = pepper
        create_credential.tap { StandardId.config.password.pepper = nil }
      end

      before { StandardId.config.password.previous_peppers = [pepper] }

      it "still authenticates the peppered digest and moves it back to the bare password" do
        loaded = stored(credential)

        expect(loaded.authenticate(password)).to be_truthy
        expect(loaded.rehash_password(password)).to be(true)
        expect(made_under?(credential, "")).to be(true)
      end

      it "writes new passwords unpeppered" do
        stored(credential).update!(password: "N3w-password!")

        expect(BCrypt::Password.new(stored(credential).password_digest).is_password?("N3w-password!")).to be(true)
      end
    end
  end
end
