require "rails_helper"

# Every password login re-hashes a digest made at another bcrypt cost
# (PasswordCredential#rehash_password). The suite hashes at MIN_COST, so a
# digest at MIN_COST + 1 stands in for one made before the cost was changed.
RSpec.describe "Re-hashing the password on login", type: :request do
  let(:email) { "rehash-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "Sup3r-secret!" }
  let(:old_cost) { BCrypt::Engine::MIN_COST + 1 }

  def credential
    StandardId::PasswordCredential.find_by!(login: email)
  end

  def digest_cost
    BCrypt::Password.new(credential.password_digest).cost
  end

  def age_digest!
    credential.update_column(:password_digest, BCrypt::Password.create(password, cost: old_cost))
  end

  def json = response.parsed_body

  shared_examples "a login that re-hashes" do
    it "re-hashes the password at the current cost" do
      expect { log_in(password) }.to change { digest_cost }.from(old_cost).to(BCrypt::Engine::MIN_COST)
      expect(credential.authenticate(password)).to be_truthy
    end

    it "publishes CREDENTIAL_PASSWORD_REHASHED" do
      events = []
      sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) { |e| events << e.payload }
      begin
        log_in(password)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      expect(events.size).to eq(1)
      expect(events.first).to include(previous_cost: old_cost, cost: BCrypt::Engine::MIN_COST)
      expect(events.first[:credential].id).to eq(credential.id)
    end

    it "leaves the digest alone on a wrong password" do
      expect { log_in("Wr0ng-password!") }.not_to change { credential.password_digest }
    end

    it "leaves the digest alone when c.password.rehash_on_login is false" do
      StandardId.config.password.rehash_on_login = false

      expect { log_in(password) }.not_to change { credential.password_digest }
    end

    it "still signs in when the rehash fails" do
      allow(StandardId::PasswordCredential).to receive(:transaction).and_call_original
      allow(StandardId::PasswordCredential).to receive(:transaction).with(requires_new: true).and_raise(ActiveRecord::StatementInvalid, "boom")
      allow(Rails.error).to receive(:report)

      expect { log_in(password) }.not_to change { credential.password_digest }
      expect_signed_in
      expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::StatementInvalid), handled: true, source: "standard_id")
    end
  end

  describe "web login (sign_in_account)" do
    before do
      create_account_with_password(email: email, password: password)
      age_digest!
    end

    def log_in(pw, remember_me: "0")
      http_post "/login", params: { login: { email: email, password: pw, remember_me: remember_me }, redirect_uri: "/after" }
    end

    def expect_signed_in
      expect(response).to redirect_to("/after")
    end

    it_behaves_like "a login that re-hashes"

    it "mints the remember-me cookie from the new digest, so it still signs in" do
      log_in(password, remember_me: "1")

      expect(digest_cost).to eq(BCrypt::Engine::MIN_COST)
      expect(StandardId::PasswordCredential.find_by_token_for(:remember_me, cookies["remember_token"])&.id).to eq(credential.id)
    end

    it "voids a remember-me token minted from the old digest" do
      old_token = credential.generate_token_for(:remember_me)
      log_in(password)

      expect(StandardId::PasswordCredential.find_by_token_for(:remember_me, old_token)).to be_nil
    end
  end

  describe "OAuth password grant" do
    before do
      create_account_with_password(email: email, password: password)
      age_digest!
    end

    def log_in(pw)
      post "/api/oauth/token", params: { grant_type: "password", username: email, password: pw, client_id: "test-client" }, as: :json
    end

    def expect_signed_in
      expect(response).to have_http_status(:ok)
      expect(json["access_token"]).to be_present
    end

    it_behaves_like "a login that re-hashes"

    it "leaves the digest alone when the grant is refused for an unverified identifier" do
      StandardId.config.oauth.password_grant_requires_verified_identifier = true
      StandardId::EmailIdentifier.find_by!(value: email).update_column(:verified_at, nil)

      expect { log_in(password) }.not_to change { credential.password_digest }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "email + password API" do
    let(:realm) { StandardId.config.email_password.verification_realm }

    before { StandardId.config.email_password.enabled = true }

    def register
      http_post_json("/api/auth/register", params: { name: "Nova", email: email, password: password })
    end

    def verify(pw)
      code = StandardId::CodeChallenge.where(realm: realm, target: email).order(created_at: :desc).first.code
      http_post_json("/api/auth/verify-email", params: { email: email, code: code, password: pw })
    end

    def expect_signed_in
      expect(response).to have_http_status(:ok)
      expect(json["access_token"]).to be_present
    end

    describe "POST /auth/login (Authentication.call)" do
      before do
        register
        verify(password)
        age_digest!
      end

      def log_in(pw)
        http_post_json("/api/auth/login", params: { email: email, password: pw })
      end

      it_behaves_like "a login that re-hashes"

      it "still refuses tokens when a reset lands between the password check and token issue" do
        sub = StandardId::Events.subscribe(StandardId::Events::PASSWORD_VALIDATED) do
          credential.update!(password: "Res3t-elsewhere!")
        end
        begin
          expect { log_in(password) }.not_to change(StandardId::RefreshToken, :count)
        ensure
          StandardId::Events.unsubscribe(sub)
        end

        expect(response).to have_http_status(:unauthorized)
        expect(credential.authenticate("Res3t-elsewhere!")).to be_truthy
      end
    end

    describe "POST /auth/verify-email (Verification.verify!)" do
      before do
        register
        age_digest!
      end

      alias_method :log_in, :verify

      it_behaves_like "a login that re-hashes"
    end
  end
end
