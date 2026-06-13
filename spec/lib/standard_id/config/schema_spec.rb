require "rails_helper"

RSpec.describe "StandardId config schema" do
  describe "passwordless scope defaults" do
    it "defaults bypass_code to nil" do
      expect(StandardId.config.passwordless.bypass_code).to be_nil
    end
  end

  describe "passwordless.bypass_code" do
    it "round-trips a non-nil value" do
      allow(StandardId.config.passwordless).to receive(:bypass_code).and_return("test-code")
      expect(StandardId.config.passwordless.bypass_code).to eq("test-code")
    end
  end

  describe "scopes field" do
    it "defaults to an empty hash" do
      expect(StandardId.config.scopes).to eq({})
    end
  end

  describe "profile_resolver field" do
    it "defaults to nil (built-in fallback used in lifecycle hooks)" do
      expect(StandardId.config.profile_resolver).to be_nil
    end
  end

  describe "scope_resolver field" do
    it "defaults to nil (built-in fallback reads request.path_parameters[:scope])" do
      expect(StandardId.config.scope_resolver).to be_nil
    end

    it "round-trips a custom callable" do
      resolver = ->(request:, session:) { :custom_scope }
      allow(StandardId.config).to receive(:scope_resolver).and_return(resolver)
      expect(StandardId.config.scope_resolver).to eq(resolver)
    end
  end

  describe "StandardId.scope_for" do
    around do |example|
      original_scopes = StandardId.config.scopes
      example.run
    ensure
      StandardId.config.scopes = original_scopes
    end

    it "returns nil when scopes is empty" do
      StandardId.config.scopes = {}
      expect(StandardId.scope_for(:borrower)).to be_nil
    end

    it "returns nil when name is nil" do
      StandardId.config.scopes = { borrower: { profile_type: "BorrowerProfile" } }
      expect(StandardId.scope_for(nil)).to be_nil
    end

    it "returns nil when name is blank" do
      StandardId.config.scopes = { borrower: { profile_type: "BorrowerProfile" } }
      expect(StandardId.scope_for("")).to be_nil
    end

    it "returns nil for an unknown scope" do
      StandardId.config.scopes = { borrower: { profile_type: "BorrowerProfile" } }
      expect(StandardId.scope_for(:admin)).to be_nil
    end

    it "returns a ScopeConfig for a known scope" do
      StandardId.config.scopes = {
        borrower: {
          profile_type: "BorrowerProfile",
          after_sign_in_path: "/borrower/dashboard",
          no_profile_message: "No borrower account found.",
          label: "Borrower Login",
          allow_registration: false
        }
      }

      scope = StandardId.scope_for(:borrower)
      expect(scope).to be_a(StandardId::ScopeConfig)
      expect(scope.name).to eq(:borrower)
      expect(scope.profile_type).to eq("BorrowerProfile")
      expect(scope.after_sign_in_path).to eq("/borrower/dashboard")
      expect(scope.allow_registration).to eq(false)
    end

    it "accepts a string name and converts to symbol lookup" do
      StandardId.config.scopes = { lender: { profile_type: "LenderProfile" } }

      scope = StandardId.scope_for("lender")
      expect(scope).to be_a(StandardId::ScopeConfig)
      expect(scope.name).to eq(:lender)
    end
  end

  describe "passwordless.delivery" do
    it "defaults to :custom" do
      expect(StandardId.config.passwordless.delivery).to eq(:custom)
    end
  end

  describe "passwordless.mailer_from" do
    it "defaults to noreply@example.com" do
      expect(StandardId.config.passwordless.mailer_from).to eq("noreply@example.com")
    end
  end

  describe "passwordless.mailer_subject" do
    it "defaults to 'Your sign-in code'" do
      expect(StandardId.config.passwordless.mailer_subject).to eq("Your sign-in code")
    end
  end

  describe "oauth.dynamic_registration_default_auth_method" do
    it "defaults to 'none' (public clients)" do
      expect(StandardId.config.oauth.dynamic_registration_default_auth_method).to eq("none")
    end

    it "round-trips a confidential auth method" do
      allow(StandardId.config.oauth)
        .to receive(:dynamic_registration_default_auth_method)
        .and_return("client_secret_basic")
      expect(StandardId.config.oauth.dynamic_registration_default_auth_method).to eq("client_secret_basic")
    end
  end
end
