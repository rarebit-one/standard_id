require "rails_helper"

RSpec.describe "passwordless.account_factory callback" do
  let(:request) do
    instance_double(
      "ActionDispatch::Request",
      remote_ip: "127.0.0.1",
      user_agent: "RSpec",
      params: ActionController::Parameters.new(timezone: "Asia/Singapore", code: "123456")
    )
  end
  let(:email) { "factory-user@example.com" }
  let(:otp_code) { "123456" }

  before do
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)
    allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(nil)
  end

  after do
    # Reset account_factory after each test
    StandardId.config.passwordless.account_factory = nil
  end

  def create_challenge(channel:, target:, code: otp_code, expires_at: 10.minutes.from_now)
    StandardId::CodeChallenge.create!(
      realm: "authentication",
      channel: channel,
      target: target,
      code: code,
      expires_at: expires_at,
      ip_address: "127.0.0.1",
      user_agent: "RSpec"
    )
  end

  def create_email_account(email_addr)
    account = Account.create!(name: "Test User", email: email_addr)
    StandardId::EmailIdentifier.create!(account: account, value: email_addr, verified_at: Time.current)
    account
  end

  describe "default behavior (no factory configured)" do
    it "uses the built-in find_or_create_account! when account_factory is nil" do
      account = create_email_account(email)
      create_challenge(channel: "email", target: email)

      result = StandardId::Passwordless::VerificationService.verify(
        email: email, code: otp_code, request: request
      )

      expect(result.success?).to be true
      expect(result.account).to eq(account)
    end

    it "uses the built-in strategy via EmailStrategy" do
      strategy = StandardId::Passwordless::EmailStrategy.new(request)
      account = create_email_account(email)

      found = strategy.find_or_create_account(email)
      expect(found).to eq(account)
    end
  end

  describe "custom factory configured" do
    let(:factory_account) { Account.create!(name: "Factory Account", email: email) }

    it "calls the factory with correct keyword arguments" do
      received_args = {}
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        received_args[:email] = email
        received_args[:params] = params
        received_args[:request] = request
        factory_account
      }

      create_challenge(channel: "email", target: email)

      result = StandardId::Passwordless::VerificationService.verify(
        email: email, code: otp_code, request: request
      )

      expect(result.success?).to be true
      expect(received_args[:email]).to eq(email)
      expect(received_args[:params]).to be_a(ActionController::Parameters)
      expect(received_args[:params][:timezone]).to eq("Asia/Singapore")
      expect(received_args[:request]).to eq(request)
    end

    it "uses the factory return value as the account" do
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        factory_account
      }

      create_challenge(channel: "email", target: email)

      result = StandardId::Passwordless::VerificationService.verify(
        email: email, code: otp_code, request: request
      )

      expect(result.success?).to be true
      expect(result.account).to eq(factory_account)
    end

    it "does not call the built-in find_or_create_account!" do
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        factory_account
      }

      # Do not create an EmailIdentifier — the built-in path would fail or
      # create one, but the factory should bypass it entirely.
      expect(Account).not_to receive(:find_or_create_by_verified_email!)

      strategy = StandardId::Passwordless::EmailStrategy.new(request)
      result = strategy.find_or_create_account(email)
      expect(result).to eq(factory_account)
    end

    it "still validates the username before calling the factory" do
      factory_called = false
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        factory_called = true
        factory_account
      }

      strategy = StandardId::Passwordless::EmailStrategy.new(request)

      expect {
        strategy.find_or_create_account("not-an-email")
      }.to raise_error(StandardId::InvalidRequestError, /Invalid email format/)
      expect(factory_called).to be false
    end

    it "passes request params to the factory" do
      received_params = nil
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        received_params = params
        factory_account
      }

      strategy = StandardId::Passwordless::EmailStrategy.new(request)
      strategy.find_or_create_account(email)

      expect(received_params[:timezone]).to eq("Asia/Singapore")
      expect(received_params[:code]).to eq("123456")
    end

    it "passes an empty hash when request has no params method" do
      bare_request = instance_double(
        "ActionDispatch::Request",
        remote_ip: "127.0.0.1",
        user_agent: "RSpec"
      )

      received_params = nil
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        received_params = params
        factory_account
      }

      strategy = StandardId::Passwordless::EmailStrategy.new(bare_request)
      strategy.find_or_create_account(email)

      expect(received_params).to eq({})
    end
  end

  describe "factory called within transaction context" do
    it "executes the factory inside the VerificationService transaction" do
      in_transaction = nil
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        # ActiveRecord::Base.connection.open_transactions > 0 means we're in a transaction
        in_transaction = ActiveRecord::Base.connection.open_transactions > 0
        Account.create!(name: "TX Account", email: email)
      }

      create_challenge(channel: "email", target: email)

      result = StandardId::Passwordless::VerificationService.verify(
        email: email, code: otp_code, request: request
      )

      expect(result.success?).to be true
      expect(in_transaction).to be true
    end

    it "rolls back factory side effects when the transaction fails" do
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        account = Account.create!(name: "Rollback Account", email: email)
        StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
        # Simulate a failure after account creation by raising
        raise ActiveRecord::RecordInvalid.new(account)
      }

      create_challenge(channel: "email", target: email)

      result = StandardId::Passwordless::VerificationService.verify(
        email: email, code: otp_code, request: request
      )

      expect(result.success?).to be false
      expect(result.error).to include("Unable to complete verification")
      # The account should have been rolled back
      expect(Account.find_by(email: email)).to be_nil
    end
  end

  describe "error handling when factory raises" do
    it "returns failure result when factory raises ActiveRecord::RecordInvalid" do
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        account = Account.new
        account.errors.add(:base, "Custom validation failed")
        raise ActiveRecord::RecordInvalid.new(account)
      }

      create_challenge(channel: "email", target: email)

      result = StandardId::Passwordless::VerificationService.verify(
        email: email, code: otp_code, request: request
      )

      expect(result.success?).to be false
      expect(result.error).to include("Unable to complete verification")
      expect(result.error).to include("Custom validation failed")
    end

    it "propagates unexpected errors from the factory" do
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        raise ArgumentError, "Something went wrong in factory"
      }

      create_challenge(channel: "email", target: email)

      expect {
        StandardId::Passwordless::VerificationService.verify(
          email: email, code: otp_code, request: request
        )
      }.to raise_error(ArgumentError, "Something went wrong in factory")
    end
  end

  describe "factory with SMS strategy" do
    let(:phone) { "+14155550199" }
    let(:phone_request) do
      instance_double(
        "ActionDispatch::Request",
        remote_ip: "127.0.0.1",
        user_agent: "RSpec",
        params: ActionController::Parameters.new(registration_code: "ABC")
      )
    end

    it "calls the factory for SMS verification too" do
      phone_account = Account.create!(name: "Phone User", email: "phone@example.com")

      received_email_arg = nil
      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        received_email_arg = email
        phone_account
      }

      create_challenge(channel: "sms", target: phone)

      result = StandardId::Passwordless::VerificationService.verify(
        phone: phone, code: otp_code, request: phone_request
      )

      expect(result.success?).to be true
      expect(result.account).to eq(phone_account)
      # The email: keyword receives the username (phone number in this case)
      expect(received_email_arg).to eq(phone)
    end
  end

  describe "factory with bypass code" do
    let(:bypass_code) { "BYPASS-E2E-FACTORY" }

    before do
      allow(StandardId.config.passwordless).to receive(:bypass_code).and_return(bypass_code)
    end

    it "uses the factory during bypass verification" do
      factory_called = false
      factory_account = Account.create!(name: "Bypass Factory", email: email)

      StandardId.config.passwordless.account_factory = lambda { |email:, params:, request:|
        factory_called = true
        factory_account
      }

      result = StandardId::Passwordless::VerificationService.verify(
        email: email, code: bypass_code, request: request
      )

      expect(result.success?).to be true
      expect(factory_called).to be true
      expect(result.account).to eq(factory_account)
    end
  end

  describe "factory that is a Proc (not just lambda)" do
    it "works with a Proc as the factory" do
      factory_account = Account.create!(name: "Proc Account", email: email)

      StandardId.config.passwordless.account_factory = Proc.new { |email:, params:, request:|
        factory_account
      }

      strategy = StandardId::Passwordless::EmailStrategy.new(request)
      result = strategy.find_or_create_account(email)
      expect(result).to eq(factory_account)
    end
  end

  describe "non-callable factory values" do
    it "ignores a string value and uses default behavior" do
      account = create_email_account(email)
      StandardId.config.passwordless.account_factory = "not_callable"

      strategy = StandardId::Passwordless::EmailStrategy.new(request)
      result = strategy.find_or_create_account(email)
      expect(result).to eq(account)
    end

    it "ignores a boolean value and uses default behavior" do
      account = create_email_account(email)
      StandardId.config.passwordless.account_factory = true

      strategy = StandardId::Passwordless::EmailStrategy.new(request)
      result = strategy.find_or_create_account(email)
      expect(result).to eq(account)
    end
  end
end
