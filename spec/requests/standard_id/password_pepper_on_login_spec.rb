require "rails_helper"

# c.password.pepper through every password login: turning it on or rotating
# it locks nobody out, and each login moves the digest to the current pepper
# (PasswordCredential#rehash_password). See StandardId::PasswordPepper.
RSpec.describe "Password pepper on login", type: :request do
  let(:email) { "pepper-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "Sup3r-secret!" }
  let(:pepper) { "current-pepper-#{"x" * 32}" }
  let(:old_pepper) { "previous-pepper-#{"y" * 32}" }

  def credential
    StandardId::PasswordCredential.find_by!(login: email)
  end

  def made_under?(pepper_value)
    BCrypt::Password.new(credential.password_digest).is_password?(StandardId::PasswordPepper.apply(password, pepper_value))
  end

  def store_digest_under!(pepper_value)
    digest = BCrypt::Password.create(StandardId::PasswordPepper.apply(password, pepper_value), cost: BCrypt::Engine::MIN_COST)
    credential.update_column(:password_digest, digest)
  end

  def bcrypt_comparisons
    StandardId::PasswordPepper::DUMMY_DIGEST.value
    count = 0
    allow(BCrypt::Engine).to receive(:hash_secret).and_wrap_original do |original, *args|
      count += 1
      original.call(*args)
    end
    yield
    count
  ensure
    allow(BCrypt::Engine).to receive(:hash_secret).and_call_original
  end

  def json = response.parsed_body

  shared_examples "a peppered login" do
    context "when the pepper is turned on over unpeppered digests" do
      before do
        store_digest_under!("")
        StandardId.config.password.pepper = pepper
      end

      it "signs in and re-hashes the digest under the pepper" do
        log_in(password)

        expect_signed_in
        expect(made_under?(pepper)).to be(true)
        expect(made_under?("")).to be(false)
      end

      it "publishes credential.password.rehashed, not credential.password.changed" do
        rehashed = []
        changed = []
        subs = [
          StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_REHASHED) { |e| rehashed << e.payload },
          StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_CHANGED) { |e| changed << e.payload }
        ]
        begin
          log_in(password)
        ensure
          subs.each { |s| StandardId::Events.unsubscribe(s) }
        end

        expect(rehashed.size).to eq(1)
        expect(rehashed.first).to include(pepper_changed: true)
        expect(changed).to be_empty
      end

      it "refuses a wrong password and leaves the digest alone" do
        expect { log_in("Wr0ng-password!") }.not_to change { credential.password_digest }
        expect_refused
      end
    end

    context "when the pepper is rotated" do
      before do
        store_digest_under!(old_pepper)
        StandardId.config.password.pepper = pepper
        StandardId.config.password.previous_peppers = [old_pepper]
      end

      it "signs in under the previous pepper and moves the digest to the current one" do
        log_in(password)

        expect_signed_in
        expect(made_under?(pepper)).to be(true)
      end

      it "costs an unknown address the same bcrypt work as a wrong password" do
        wrong = bcrypt_comparisons { log_in("Wr0ng-password!") }
        expect_refused
        unknown = bcrypt_comparisons { log_in("Wr0ng-password!", login: "nobody-#{SecureRandom.hex(4)}@example.com") }
        expect_refused

        expect(wrong).to eq(StandardId::PasswordPepper.candidates.size)
        expect(unknown).to eq(wrong)
      end
    end

    context "with the pepper already current" do
      before do
        StandardId.config.password.pepper = pepper
        store_digest_under!(pepper)
      end

      it "signs in without touching the digest" do
        expect { log_in(password) }.not_to change { credential.password_digest }
        expect_signed_in
      end
    end

    context "with no pepper (the default)" do
      it "signs in without touching the digest" do
        store_digest_under!("")

        expect { log_in(password) }.not_to change { credential.password_digest }
        expect_signed_in
      end

      it "costs one comparison for an unknown address and for a wrong password, as before" do
        expect(bcrypt_comparisons { log_in("Wr0ng-password!") }).to eq(1)
        expect(bcrypt_comparisons { log_in("Wr0ng-password!", login: "nobody-#{SecureRandom.hex(4)}@example.com") }).to eq(1)
      end
    end
  end

  describe "web login (sign_in_account)" do
    before { create_account_with_password(email: email, password: password) }

    def log_in(pw, login: email)
      http_post "/login", params: { login: { email: login, password: pw }, redirect_uri: "/after" }
    end

    def expect_signed_in
      expect(response).to redirect_to("/after")
    end

    def expect_refused
      expect(response).not_to redirect_to("/after")
    end

    it_behaves_like "a peppered login"
  end

  describe "OAuth password grant" do
    before { create_account_with_password(email: email, password: password) }

    def log_in(pw, login: email)
      post "/api/oauth/token", params: { grant_type: "password", username: login, password: pw, client_id: "test-client" }, as: :json
    end

    def expect_signed_in
      expect(response).to have_http_status(:ok)
      expect(json["access_token"]).to be_present
    end

    def expect_refused
      expect(response).to have_http_status(:bad_request)
    end

    it_behaves_like "a peppered login"
  end

  describe "email + password API login (Authentication.call)" do
    before do
      StandardId.config.email_password.enabled = true
      create_account_with_password(email: email, password: password)
    end

    def log_in(pw, login: email)
      http_post_json("/api/auth/login", params: { email: login, password: pw })
    end

    def expect_signed_in
      expect(response).to have_http_status(:ok)
      expect(json["access_token"]).to be_present
    end

    def expect_refused
      expect(response).to have_http_status(:unauthorized)
    end

    it_behaves_like "a peppered login"
  end

  describe "email + password API sign-up under a pepper" do
    before do
      StandardId.config.email_password.enabled = true
      StandardId.config.password.pepper = pepper
    end

    it "stores the new password peppered, and verify-email signs in with it" do
      http_post_json("/api/auth/register", params: { name: "Nova", email: email, password: password })
      expect(made_under?(pepper)).to be(true)

      http_post_json("/api/auth/verify-email", params: { email: email, code: issued_otp_code(email), password: password })
      expect(response).to have_http_status(:ok)
      expect(json["access_token"]).to be_present
    end

    it "re-hashes an unpeppered pending sign-up when verify-email succeeds" do
      StandardId.config.password.pepper = nil
      http_post_json("/api/auth/register", params: { name: "Nova", email: email, password: password })
      StandardId.config.password.pepper = pepper

      http_post_json("/api/auth/verify-email", params: { email: email, code: issued_otp_code(email), password: password })
      expect(response).to have_http_status(:ok)
      expect(made_under?(pepper)).to be(true)
    end
  end
end
