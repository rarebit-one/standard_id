require "rails_helper"

# Ported from luminality-web's spec/requests/api/auth/email_auth_spec.rb, the
# app this API was extracted from.
RSpec.describe "API email + password", type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:auth) { "/api/auth" }
  let(:email) { "new.user@example.com" }
  let(:password) { "Sup3r-secret!" }
  let(:realm) { StandardId.config.email_password.verification_realm }

  before do
    StandardId.config.email_password.enabled = true
    StandardId.config.email_password.reset_url = "https://app.example.com/password-reset?token={token}"
  end

  def json = response.parsed_body

  def post_json(path, params, headers: {})
    http_post_json(path, params: params, headers: headers)
  end

  def register(name: "Nova", email: self.email, password: self.password, headers: {})
    post_json("#{auth}/register", { name: name, email: email, password: password }.compact, headers: headers)
  end

  def verify(code:, email: self.email, password: self.password, headers: {})
    post_json("#{auth}/verify-email", { email: email, code: code, password: password }, headers: headers)
  end

  def resend(email: self.email, password: self.password, headers: {})
    post_json("#{auth}/verify-email/resend", { email: email, password: password }, headers: headers)
  end

  def login(email: self.email, password: self.password, headers: {})
    post_json("#{auth}/login", { email: email, password: password }, headers: headers)
  end

  def forgot(email: self.email, headers: {})
    post_json("#{auth}/password/forgot", { email: email }, headers: headers)
  end

  def reset(token:, password: "N3w-passphrase!", **extra)
    post_json("#{auth}/password/reset", { token: token, password: password, **extra })
  end

  def latest_code(target = email)
    StandardId::CodeChallenge.where(realm: realm, target: target).order(created_at: :desc).first&.code
  end

  def identifier_for(address = email)
    StandardId::EmailIdentifier.includes(:account).find_by(value: address)
  end

  def password_credential_for(address = email)
    StandardId::EmailPassword.find_password_credential(address)
  end

  def create_verified_account(email: self.email, password: self.password)
    register(email: email, password: password)
    verify(email: email, code: latest_code(email), password: password)
    expect(response).to have_http_status(:ok)
    identifier_for(email).account
  end

  # An account that signs in only through a provider.
  def create_social_account(address)
    account = Account.create!(email: address, name: "Social")
    StandardId::EmailIdentifier.create!(account: account, value: address, provider: "google")
    account
  end

  def expect_token_response
    expect(json).to include("access_token", "refresh_token", "expires_in")
    expect(json["token_type"]).to eq("Bearer")
  end

  def use_memory_cache!
    StandardId.config.cache_store = ActiveSupport::Cache::MemoryStore.new
  end

  describe "when c.email_password.enabled is false" do
    before { StandardId.config.email_password.enabled = false }

    it "does not serve the endpoints" do
      register
      expect(response).to have_http_status(:not_found)
      expect(Account.count).to eq(0)
    end
  end

  describe "sign-up, then verify-email, then tokens" do
    it "creates an unverified account, emails a 6-digit code and issues no tokens" do
      expect { register }
        .to change(Account, :count).by(1)
        .and have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)

      expect(response).to have_http_status(:accepted)
      expect(json).to eq("status" => "verification_required", "email" => email)
      expect(identifier_for).not_to be_verified
      expect(latest_code).to match(/\A\d{6}\z/)
      expect(identifier_for.account.name).to eq("Nova")
    end

    it "normalises the address" do
      register(email: "  New.User@Example.COM ")

      expect(json["email"]).to eq(email)
      expect(identifier_for).to be_present
    end

    it "mails the code with the gem's verification email" do
      perform_enqueued_jobs { register }

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([email])
      expect(mail.text_part.body.to_s).to include(latest_code)
    end

    it "publishes the code instead of mailing it when code_delivery is :custom" do
      StandardId.config.email_password.code_delivery = :custom
      codes = capture_passwordless_codes

      expect { register }.not_to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)
      expect(codes).to contain_exactly([email, latest_code])
    end

    it "verifies the address and returns tokens" do
      register
      verify(code: latest_code)

      expect(response).to have_http_status(:ok)
      expect_token_response
      expect(identifier_for).to be_verified
    end

    it "runs after_email_verified with the name given at sign-up" do
      seen = nil
      StandardId.config.email_password.after_email_verified = ->(account:, name:) { seen = [account.email, name] }

      register(name: "Nova Star")
      verify(code: latest_code)

      expect(seen).to eq([email, "Nova Star"])
    end

    it "leaves the address unverified, so a new code can retry the hook, when after_email_verified raises" do
      calls = 0
      StandardId.config.email_password.after_email_verified = lambda { |account:|
        calls += 1
        raise "provisioning down" if calls == 1
      }
      register

      expect { verify(code: latest_code) }.to raise_error("provisioning down")
      expect(identifier_for).not_to be_verified

      travel(StandardId.config.passwordless.retry_delay + 1) do
        resend
        verify(code: latest_code)
      end
      expect(response).to have_http_status(:ok)
      expect(calls).to eq(2)
      expect(identifier_for).to be_verified
    end

    it "still returns tokens when an IDENTIFIER_VERIFICATION_SUCCEEDED subscriber fails" do
      sub = StandardId::Events.subscribe(StandardId::Events::IDENTIFIER_VERIFICATION_SUCCEEDED) { raise "subscriber down" }
      register

      begin
        verify(code: latest_code)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      expect(response).to have_http_status(:ok)
      expect(json["access_token"]).to be_present
      expect(identifier_for).to be_verified
    end

    it "publishes IDENTIFIER_VERIFICATION_SUCCEEDED only once the verification commits" do
      events = []
      sub = StandardId::Events.subscribe(StandardId::Events::IDENTIFIER_VERIFICATION_SUCCEEDED) { |e| events << e }
      calls = 0
      StandardId.config.email_password.after_email_verified = lambda { |account:|
        calls += 1
        raise "provisioning down" if calls == 1
      }
      register

      begin
        expect { verify(code: latest_code) }.to raise_error("provisioning down")
        expect(events).to be_empty

        travel(StandardId.config.passwordless.retry_delay + 1) do
          resend
          verify(code: latest_code)
        end
      ensure
        StandardId::Events.unsubscribe(sub)
      end
      expect(events.size).to eq(1)
    end

    it "answers a sign-up that loses the race to the uniqueness validation as account_exists" do
      create_verified_account
      allow(StandardId::EmailPassword).to receive(:find_password_credential).and_return(nil)
      allow(StandardId::EmailIdentifier).to receive(:exists?).and_return(false)

      expect { register }.not_to change(Account, :count)

      expect(response).to have_http_status(:conflict)
      expect(json["error"]).to eq("account_exists")
    end

    it "answers a host validation failure as invalid_request" do
      StandardId.config.email_password.account_creator = lambda { |email:|
        account = Account.new(email: email)
        account.errors.add(:email, "is not allowed")
        raise ActiveRecord::RecordInvalid, account
      }
      register

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to eq("invalid_request")
      expect(Account.where(email: email)).to be_empty
    end

    it "mints tokens that refresh through /oauth/token with the configured client_id" do
      register
      verify(code: latest_code)

      post_json("/api/oauth/token", {
        grant_type: "refresh_token",
        refresh_token: json["refresh_token"],
        client_id: StandardId.config.email_password.token_client_id
      })

      expect(response).to have_http_status(:ok)
      expect(json).to include("access_token")
    end

    it "uses account_creator when configured" do
      StandardId.config.email_password.account_creator = lambda { |email:, name:|
        Account.create!(email: email, name: "#{name} (hooked)")
      }

      register

      expect(identifier_for.account.name).to eq("Nova (hooked)")
    end

    it "requires a name only when require_name is set" do
      StandardId.config.email_password.require_name = true
      register(name: nil)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to eq("invalid_request")
      expect(json["details"]).to eq("name" => ["can't be blank"])
      expect(Account.count).to eq(0)
    end

    it "rejects an invalid email" do
      register(email: "not-an-email")

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["details"]).to eq("email" => ["is invalid"])
    end

    it "rejects a password that fails the engine's password rules" do
      register(password: "short")

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to eq("weak_password")
      expect(json.dig("details", "password").first).to match(/at least \d+ characters/)
      expect(Account.count).to eq(0)
    end

    it "rejects a password the password_validator refuses" do
      StandardId.config.email_password.password_validator = ->(password:) { password.include?("secret") ? ["has appeared in a data breach"] : [] }

      register

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["details"]).to eq("password" => ["has appeared in a data breach"])
    end

    it "re-sending sign-up with the SAME pending password sends a fresh code" do
      register
      first_code = latest_code

      travel(StandardId.config.passwordless.retry_delay + 1) do
        expect { register }.to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)
      end

      expect(response).to have_http_status(:accepted)
      expect(latest_code).not_to eq(first_code)
      expect(Account.count).to eq(1)
    end

    it "rejects sign-up for an address that already has a verified password account" do
      create_verified_account
      register

      expect(response).to have_http_status(:conflict)
      expect(json["error"]).to eq("account_exists")
    end
  end

  describe "an address that belongs to a social-only account" do
    before { create_social_account(email) }

    it "is rejected with a distinct error, without linking" do
      expect { register }.not_to change(StandardId::PasswordCredential, :count)

      expect(response).to have_http_status(:conflict)
      expect(json["error"]).to eq("social_account")
    end

    it "matches regardless of case and surrounding whitespace" do
      register(email: "  NEW.user@example.com ")
      expect(json["error"]).to eq("social_account")
    end

    it "cannot be logged into with a password" do
      login
      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to eq("invalid_credentials")
    end
  end

  describe "with reveal_existing_accounts = false" do
    before { StandardId.config.email_password.reveal_existing_accounts = false }

    it "answers an existing verified account like a fresh sign-up and emails the owner" do
      create_verified_account

      expect { register(password: "Other-passw0rd!") }
        .to have_enqueued_mail(StandardId::AccountNoticeMailer, :existing_account)
      expect(response).to have_http_status(:accepted)
      expect(json).to eq("status" => "verification_required", "email" => email)
    end

    it "does the same bcrypt work for an existing account as for a new one" do
      hashes = 0
      allow(BCrypt::Password).to receive(:create).and_wrap_original { |original, *args, **kw| hashes += 1; original.call(*args, **kw) }
      register(email: "fresh@example.com")
      for_new_address = hashes
      create_verified_account
      create_social_account("social@example.com")

      [email, "social@example.com"].each do |address|
        hashes = 0
        register(email: address, password: "Other-passw0rd!")
        expect(hashes).to eq(for_new_address), "#{address}: #{hashes} bcrypt hashes, a new address costs #{for_new_address}"
      end
    end

    it "answers a social-only account the same way" do
      create_social_account(email)

      expect { register }.to have_enqueued_mail(StandardId::AccountNoticeMailer, :existing_account)
      expect(response).to have_http_status(:accepted)
    end

    it "caps the notices per address per day" do
      use_memory_cache!
      StandardId.config.rate_limits.email_password_codes_per_day = 2
      create_social_account(email)

      expect { 3.times { register } }
        .to have_enqueued_mail(StandardId::AccountNoticeMailer, :existing_account).exactly(2).times
    end
  end

  describe "takeover by re-registering a pending address" do
    before { register }

    it "does not replace the pending password, sends nothing, and answers like a fresh sign-up" do
      digest = password_credential_for.password_digest

      travel(StandardId.config.passwordless.retry_delay + 1) do
        expect { register(password: "Attack3r-pass!") }
          .not_to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)
      end

      expect(response).to have_http_status(:accepted)
      expect(json).to eq("status" => "verification_required", "email" => email)
      expect(password_credential_for.reload.password_digest).to eq(digest)
    end

    it "cannot verify with the owner's code and the attacker's password" do
      verify(code: latest_code, password: "Attack3r-pass!")

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to eq("invalid_code")
      expect(identifier_for).not_to be_verified
    end
  end

  describe "POST /auth/login" do
    it "returns tokens for a verified account" do
      create_verified_account
      login

      expect(response).to have_http_status(:ok)
      expect_token_response
    end

    it "is case-insensitive on the email" do
      create_verified_account
      login(email: "NEW.USER@example.com")

      expect(response).to have_http_status(:ok)
    end

    it "refuses tokens when a password reset lands between the password check and token issue" do
      create_verified_account
      sub = StandardId::Events.subscribe(StandardId::Events::PASSWORD_VALIDATED) do
        password_credential_for.update!(password: "Res3t-elsewhere!")
      end
      begin
        expect { login }.not_to change(StandardId::RefreshToken, :count)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to eq("invalid_credentials")
    end

    it "gives the same answer for a wrong password and an unknown email" do
      create_verified_account

      login(password: "Wrong-passw0rd!")
      wrong_password = [response.status, json]
      login(email: "nobody@example.com")

      expect([response.status, json]).to eq(wrong_password)
      expect(json).to eq("error" => "invalid_credentials", "error_description" => "Invalid email or password")
    end

    it "answers :unverified only when the password is right" do
      register

      login
      expect(response).to have_http_status(:forbidden)
      expect(json["error"]).to eq("unverified")

      login(password: "Wrong-passw0rd!")
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a deactivated account with the generic error" do
      account = create_verified_account
      account.update!(status: "inactive", deactivated_at: Time.current)

      login

      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to eq("invalid_credentials")
    end

    it "refuses a locked account with the generic error" do
      account = create_verified_account
      account.update!(locked: true, locked_at: Time.current)

      login

      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to eq("invalid_credentials")
    end

    it "applies the login_method_policy with flow :api_email_password" do
      create_verified_account
      seen = nil
      StandardId.config.login_method_policy = lambda { |flow:|
        seen = flow
        raise StandardId::LoginMethodDenied, "Staff must use SSO"
      }

      login

      expect(seen).to eq(:api_email_password)
      expect(response).to have_http_status(:forbidden)
      expect(json).to include("error" => "login_method_denied", "error_description" => "Staff must use SSO")
    end
  end

  describe "verify-email codes" do
    before { register }

    it "requires the sign-up password: a correct code alone is refused and not consumed" do
      code = latest_code
      verify(code: code, password: nil)
      expect(response).to have_http_status(:unprocessable_content)

      verify(code: code)
      expect(response).to have_http_status(:ok)
    end

    it "refuses, leaving the address unverified, when a password reset lands before the verification" do
      allow(StandardId::Otp).to receive(:verify).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { password_credential_for.update!(password: "Res3t-elsewhere!") }
      end

      expect { verify(code: latest_code) }.not_to change(StandardId::RefreshToken, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to eq("invalid_code")
      expect(identifier_for).not_to be_verified
    end

    it "refuses tokens when a password reset lands between the verification and token issue" do
      sub = StandardId::Events.subscribe(StandardId::Events::IDENTIFIER_VERIFICATION_SUCCEEDED) do
        password_credential_for.update!(password: "Res3t-elsewhere!")
      end
      begin
        expect { verify(code: latest_code) }.not_to change(StandardId::RefreshToken, :count)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to eq("invalid_code")
    end

    it "answers a wrong password exactly like a wrong code" do
      verify(code: latest_code, password: "Wrong-passw0rd!")
      wrong_password = json

      verify(code: "000000")

      expect(json).to eq(wrong_password)
    end

    it "rejects a reused code" do
      code = latest_code
      verify(code: code)
      verify(code: code)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an expired code" do
      code = latest_code
      travel(StandardId.config.passwordless.code_ttl + 1) { verify(code: code) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(identifier_for).not_to be_verified
    end

    it "burns the code after too many wrong attempts" do
      code = latest_code
      StandardId::Passwordless.max_attempts_per_challenge.times { verify(code: "000000") }

      verify(code: code)

      expect(response).to have_http_status(:unprocessable_content)
      expect(identifier_for).not_to be_verified
    end

    it "answers identically for an address with nothing to verify" do
      verify(code: "000000")
      pending_answer = json

      verify(email: "nobody@example.com", code: "000000")

      expect(json).to eq(pending_answer)
    end
  end

  describe "POST /auth/verify-email/resend" do
    it "sends a fresh code for a pending sign-up, carrying the name forward" do
      register(name: "Nova Star")
      seen = nil
      StandardId.config.email_password.after_email_verified = ->(name:) { seen = name }

      travel(StandardId.config.passwordless.retry_delay + 1) do
        expect { resend }.to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)
        expect(response).to have_http_status(:accepted)
        expect(json).to eq("status" => "verification_sent")

        verify(code: latest_code)
      end

      expect(seen).to eq("Nova Star")
    end

    it "answers identically, and sends nothing, for unknown and verified addresses" do
      create_verified_account(email: "done@example.com")

      expect { resend(email: "nobody@example.com") }.not_to have_enqueued_mail
      expect(response).to have_http_status(:accepted)
      expect { resend(email: "done@example.com") }.not_to have_enqueued_mail
      expect(response).to have_http_status(:accepted)
    end

    it "requires the sign-up password" do
      register

      travel(StandardId.config.passwordless.retry_delay + 1) do
        expect { resend(password: "Wrong-passw0rd!") }.not_to have_enqueued_mail
      end
      expect(response).to have_http_status(:accepted)
    end
  end

  describe "POST /auth/password/forgot" do
    it "gives the same response whether or not the email has an account" do
      create_verified_account

      forgot
      known = [response.status, json]
      forgot(email: "nobody@example.com")

      expect([response.status, json]).to eq(known)
      expect(json).to eq("status" => "reset_requested")
    end

    it "does the lookup in PasswordResetDeliveryJob, with the configured link" do
      expect { forgot }.to have_enqueued_job(StandardId::PasswordResetDeliveryJob)
        .with(email: email, reset_url_template: "https://app.example.com/password-reset?token={token}")
    end

    it "accepts a callable reset_url" do
      StandardId.config.email_password.reset_url = ->(request:) { "https://#{request.host}/r?t={token}" }

      expect { forgot }.to have_enqueued_job(StandardId::PasswordResetDeliveryJob)
        .with(email: email, reset_url_template: "https://www.example.com/r?t={token}")
    end

    it "publishes the reset link for a known address" do
      create_verified_account
      urls = []
      sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED) { |e| urls << e[:reset_url] }

      perform_enqueued_jobs(only: StandardId::PasswordResetDeliveryJob) { forgot }

      expect(urls.sole).to start_with("https://app.example.com/password-reset?token=")
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end

    it "raises a ConfigurationError when reset_url is missing" do
      StandardId.config.email_password.reset_url = nil

      expect { forgot }.to raise_error(StandardId::ConfigurationError, /reset_url/)
    end
  end

  describe "POST /auth/password/reset" do
    let!(:account) { create_verified_account }
    let(:token) { password_credential_for.generate_token_for(:password_reset) }

    it "sets the new password" do
      reset(token: token)

      expect(response).to have_http_status(:ok)
      expect(json).to eq("status" => "password_reset")
      login(password: "N3w-passphrase!")
      expect(response).to have_http_status(:ok)
    end

    it "is single use" do
      issued = token
      reset(token: issued)
      reset(token: issued, password: "An0ther-passphrase!")

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to eq("invalid_reset_token")
    end

    it "rejects a tampered token" do
      reset(token: "#{token}x")
      expect(json["error"]).to eq("invalid_reset_token")
    end

    it "rejects an expired token" do
      issued = token
      travel(1.day) { reset(token: issued) }
      expect(json["error"]).to eq("invalid_reset_token")
    end

    it "revokes every refresh token and session" do
      login
      refresh_token = json["refresh_token"]

      reset(token: token)

      expect(StandardId::RefreshToken.where(account_id: account.id, revoked_at: nil)).to be_empty
      post_json("/api/oauth/token", {
        grant_type: "refresh_token", refresh_token: refresh_token,
        client_id: StandardId.config.email_password.token_client_id
      })
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a password that fails the rules, leaving the token usable" do
      issued = token
      reset(token: issued, password: "short")
      expect(json["error"]).to eq("weak_password")

      reset(token: issued)
      expect(response).to have_http_status(:ok)
    end

    it "rejects a blank password without consuming the token" do
      issued = token
      reset(token: issued, password: "")
      expect(json.dig("details", "password")).to eq(["can't be blank"])

      reset(token: issued)
      expect(response).to have_http_status(:ok)
    end

    it "checks password_confirmation when given" do
      reset(token: token, password_confirmation: "Something-else1!")

      expect(json.dig("details", "password_confirmation")).to eq(["doesn't match Password"])
    end

    it "marks a never-verified address as verified (the link proved the inbox)" do
      register(email: "pending@example.com")
      pending_token = password_credential_for("pending@example.com").generate_token_for(:password_reset)

      reset(token: pending_token)

      expect(identifier_for("pending@example.com")).to be_verified
    end

    it "runs after_email_verified, once, when it verifies a pending sign-up" do
      seen = []
      StandardId.config.email_password.after_email_verified = ->(account:, name:) { seen << [account.email, name] }
      register(email: "pending@example.com", name: "Nova Star")

      reset(token: password_credential_for("pending@example.com").generate_token_for(:password_reset))
      reset(token: password_credential_for("pending@example.com").generate_token_for(:password_reset), password: "An0ther-passphrase!")

      expect(response).to have_http_status(:ok)
      expect(seen).to eq([["pending@example.com", "Nova Star"]])
    end

    it "changes nothing, and the link still works, when after_email_verified raises" do
      StandardId.config.email_password.after_email_verified = ->(account:) { raise "provisioning down" }
      register(email: "pending@example.com")
      pending_token = password_credential_for("pending@example.com").generate_token_for(:password_reset)

      expect { reset(token: pending_token) }.to raise_error("provisioning down")
      expect(identifier_for("pending@example.com")).not_to be_verified
      expect(StandardId::EmailPassword::PasswordReset.valid_token?(pending_token)).to be(true)
    end

    it "verifies, without running after_email_verified, an unverified address that did not sign up here" do
      calls = 0
      StandardId.config.email_password.after_email_verified = ->(account:) { calls += 1 }
      create_account_with_password(email: "websignup@example.com", password: "Sup3r-secret!", name: "Web")
      identifier_for("websignup@example.com").update_columns(verified_at: nil)

      reset(token: password_credential_for("websignup@example.com").generate_token_for(:password_reset))

      expect(response).to have_http_status(:ok)
      expect(identifier_for("websignup@example.com")).to be_verified
      expect(calls).to eq(0)
    end

    it "still answers, and publishes CREDENTIAL_PASSWORD_RESET_COMPLETED, when a verification subscriber fails" do
      completed = []
      failing = StandardId::Events.subscribe(StandardId::Events::IDENTIFIER_VERIFICATION_SUCCEEDED) { raise "subscriber down" }
      done = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_COMPLETED) { |e| completed << e }
      register(email: "pending@example.com")

      begin
        reset(token: password_credential_for("pending@example.com").generate_token_for(:password_reset))
      ensure
        StandardId::Events.unsubscribe(failing)
        StandardId::Events.unsubscribe(done)
      end

      expect(response).to have_http_status(:ok)
      expect(identifier_for("pending@example.com")).to be_verified
      expect(completed.size).to eq(1)
    end

    it "does not run after_email_verified, or look up the sign-up, for an address that was already verified" do
      calls = 0
      StandardId.config.email_password.after_email_verified = ->(account:) { calls += 1 }
      expect(StandardId::EmailPassword).not_to receive(:signup_challenge)

      reset(token: token)

      expect(response).to have_http_status(:ok)
      expect(calls).to eq(0)
    end

    it "publishes CREDENTIAL_PASSWORD_RESET_COMPLETED" do
      events = []
      sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_COMPLETED) { |e| events << e[:account] }

      reset(token: token)

      expect(events).to eq([account])
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end

    it "still answers 200, and logs, when a RESET_COMPLETED subscriber raises" do
      sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_RESET_COMPLETED) { raise "boom" }
      allow(StandardId.logger).to receive(:error)

      reset(token: token)

      expect(response).to have_http_status(:ok)
      expect(StandardId.logger).to have_received(:error).with(/CREDENTIAL_PASSWORD_RESET_COMPLETED.*boom/)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end
  end

  describe "daily caps" do
    before { use_memory_cache! }

    it "locks an address out of verify-email for the day after too many failures, even with the right code" do
      StandardId.config.rate_limits.email_password_failed_verifications_per_day = 3
      register
      code = latest_code

      3.times do |i|
        travel((i + 1) * StandardId.config.passwordless.retry_delay + 1) do
          resend
          verify(code: "000000")
        end
      end
      expect(json["error_description"]).to eq(StandardId::EmailPassword::Verification::LOCKED_OUT_MESSAGE)

      verify(code: code)
      expect(response).to have_http_status(:unprocessable_content)

      travel(25.hours) do
        resend
        verify(code: latest_code)
        expect(response).to have_http_status(:ok)
      end
    end

    it "tells only the right password that the address is locked out" do
      StandardId.config.rate_limits.email_password_failed_verifications_per_day = 1
      register
      verify(code: "000000")

      verify(code: latest_code, password: "Wrong-passw0rd!")
      expect(json["error_description"]).to eq(StandardId::EmailPassword::Verification::INVALID_CODE_MESSAGE)

      verify(code: latest_code)
      expect(json["error_description"]).to eq(StandardId::EmailPassword::Verification::LOCKED_OUT_MESSAGE)
    end

    it "does not count wrong-password attempts toward the lockout" do
      StandardId.config.rate_limits.email_password_failed_verifications_per_day = 2
      register

      3.times { verify(code: "000000", password: "Wrong-passw0rd!") }
      verify(code: latest_code)

      expect(response).to have_http_status(:ok)
    end

    it "caps verification codes emailed per address per day" do
      StandardId.config.rate_limits.email_password_codes_per_day = 2
      register

      expect {
        3.times { |i| travel((i + 1) * (StandardId.config.passwordless.retry_delay + 1)) { resend } }
      }.to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email).once
    end

    it "caps forgot-password per address per network, and per address overall" do
      StandardId.config.rate_limits.email_password_reset_requests_per_network_per_day = 2
      StandardId.config.rate_limits.email_password_reset_requests_per_day = 3
      StandardId.config.email_password.client_key = ->(request:) { request.headers["X-Network"] }
      networks = %w[net-a net-a net-a net-b net-b net-c]

      # 16 minutes apart, past the per-address password_reset_start_per_target window.
      expect {
        networks.each_with_index { |net, i| travel(i * 16.minutes) { forgot(headers: { "X-Network" => net }) } }
      }.to have_enqueued_job(StandardId::PasswordResetDeliveryJob).exactly(3).times
      expect(response).to have_http_status(:accepted)
    end
  end

  describe "rate limits" do
    let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
        .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
    end

    it "limits login per email across IPs, with a Retry-After" do
      StandardId.config.rate_limits.login_per_email.times { |i| login(headers: { "REMOTE_ADDR" => "10.0.0.#{i}" }) }

      login(headers: { "REMOTE_ADDR" => "10.0.1.1" })

      expect(response).to have_http_status(:too_many_requests)
      expect(json["error"]).to eq("rate_limited")
      expect(response.headers["Retry-After"]).to eq(15.minutes.to_i.to_s)
    end

    it "limits sign-up per IP across emails" do
      StandardId.config.rate_limits.signup_per_ip.times { |i| register(email: "user#{i}@example.com") }

      register(email: "another@example.com")

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq(1.hour.to_i.to_s)
    end

    it "counts per client_key when configured" do
      StandardId.config.email_password.client_key = -> { "one-network" }
      StandardId.config.rate_limits.signup_per_ip.times { |i| register(email: "user#{i}@example.com", headers: { "REMOTE_ADDR" => "10.0.0.#{i}" }) }

      register(email: "another@example.com", headers: { "REMOTE_ADDR" => "10.9.9.9" })

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "c.email_password.error_renderer" do
    it "renders the body the hook returns, with the error's status" do
      StandardId.config.email_password.error_renderer = lambda { |error:|
        { error: { code: "EMAIL_#{error.code}", message: error.message, details: error.details.presence }.compact }
      }

      login

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => { "code" => "EMAIL_invalid_credentials", "message" => "Invalid email or password" })
    end
  end
end
