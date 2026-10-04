require "rails_helper"

# Providers::Base.trusted_for_linking? (0.45): lets the :strict link_strategy
# link an org-IdP login to an existing account created through another
# provider. Every other 0.44 (L1-01) guard must still hold.
RSpec.describe StandardId::SocialAuthentication, "trusted_for_linking?" do
  let(:dummy_class) do
    Class.new(ActionController::Base) do
      include StandardId::SocialAuthentication
    end
  end
  let(:instance) { dummy_class.new }

  def provider_class(name:, trusted:)
    Class.new(StandardId::Providers::Base) do
      define_singleton_method(:provider_name) { name }
      define_singleton_method(:trusted_for_linking?) { trusted }
    end
  end

  let(:trusted_provider) { provider_class(name: "org_idp", trusted: true) }
  let(:untrusted_provider) { provider_class(name: "org_idp", trusted: false) }
  let(:provider) { trusted_provider }

  let(:email) { "staff-#{SecureRandom.hex(4)}@example.com" }
  let(:sub) { "ed25519:#{SecureRandom.hex(8)}" }
  let!(:existing_account) { Account.create!(email: email, name: "Existing") }
  let(:identifier_verified_at) { Time.current }
  let!(:identifier) do
    # Created by a Google login: the case :strict refuses without the hook.
    StandardId::EmailIdentifier.create!(account: existing_account, value: email, provider: "google", verified_at: identifier_verified_at)
  end

  around do |example|
    original = StandardId.config.social.link_strategy
    StandardId.config.social.link_strategy = :strict
    example.run
  ensure
    StandardId.config.social.link_strategy = original
  end

  before do
    allow(instance).to receive(:provider).and_return(provider)
    allow(instance).to receive(:resolve_account_attributes).and_return({ name: "New", email: email })
  end

  def login(info)
    instance.send(:find_or_create_account_from_social, info.with_indifferent_access)
  end

  def expect_refusal(info, reason)
    expect {
      expect { login(info) }.to raise_error(StandardId::SocialLinkError) { |error| expect(error.reason).to eq(reason) }
    }.not_to change { [Account.count, StandardId::SocialIdentity.count] }
  end

  describe "the default" do
    it "is false on Providers::Base" do
      expect(StandardId::Providers::Base.trusted_for_linking?).to be(false)
    end

    it "is false for every provider registered in the dummy app (Google, Apple)" do
      StandardId::ProviderRegistry.providers.each_value do |klass|
        expect(klass.trusted_for_linking?).to be(false), "#{klass} must not be trusted for linking by default"
      end
    end
  end

  context "when every condition holds (trusted provider, verified provider email, verified identifier)" do
    it "links to the existing account and records the subject" do
      result = login(email: email, email_verified: true, sub: sub)

      expect(result).to eq(existing_account)
      expect(StandardId::SocialIdentity.find_by(provider: "org_idp", subject: sub)&.account_id).to eq(existing_account.id)
      expect(identifier.reload.provider).to eq("google") # the identifier's origin is not rewritten
    end

    it "accepts the string \"true\"" do
      expect(login(email: email, email_verified: "true", sub: sub)).to eq(existing_account)
    end

    it "matches on the stored subject at the next login" do
      login(email: email, email_verified: true, sub: sub)

      expect(login(email: "changed-#{email}", email_verified: false, sub: sub)).to eq(existing_account)
    end
  end

  context "when the provider does not assert email_verified" do
    [false, "false", nil, "", "yes", "1"].each do |value|
      it "refuses with :email_unverified for email_verified=#{value.inspect}" do
        expect_refusal({ email: email, email_verified: value, sub: sub }, :email_unverified)
      end
    end

    it "refuses with :email_unverified when the claim is omitted" do
      expect_refusal({ email: email, sub: sub }, :email_unverified)
    end
  end

  context "when the provider is not trusted for linking" do
    let(:provider) { untrusted_provider }

    it "refuses with :link_required, exactly as 0.44" do
      expect_refusal({ email: email, email_verified: true, sub: sub }, :link_required)
    end
  end

  context "when the provider returns a truthy value that is not true" do
    let(:provider) { provider_class(name: "org_idp", trusted: "true") }

    it "refuses with :link_required (the opt-in must be literally true)" do
      expect_refusal({ email: email, email_verified: true, sub: sub }, :link_required)
    end
  end

  context "when the existing identifier is not verified" do
    let(:identifier_verified_at) { nil }

    it "refuses with :link_required (pre-account-hijacking guard)" do
      expect_refusal({ email: email, email_verified: true, sub: sub }, :link_required)
    end
  end

  context "when the identifier is already linked to a different subject from the trusted provider" do
    before do
      StandardId::SocialIdentity.create!(account: existing_account, identifier: identifier, provider: "org_idp", subject: "ed25519:other")
    end

    it "refuses with :subject_mismatch" do
      expect_refusal({ email: email, email_verified: true, sub: sub }, :subject_mismatch)
    end
  end

  context "when the (provider, sub) is already linked to another account" do
    let!(:other_account) { Account.create!(email: "other-#{email}", name: "Other") }

    before do
      other_identifier = StandardId::EmailIdentifier.create!(account: other_account, value: "other-#{email}", provider: "org_idp", verified_at: Time.current)
      StandardId::SocialIdentity.create!(account: other_account, identifier: other_identifier, provider: "org_idp", subject: sub)
    end

    it "returns the subject's account, not the email's" do
      expect(login(email: email, email_verified: true, sub: sub)).to eq(other_account)
    end
  end

  context "when no account holds the email" do
    it "creates a new account as before" do
      fresh = "fresh-#{email}"
      allow(instance).to receive(:resolve_account_attributes).and_return({ name: "New", email: fresh })

      expect { login(email: fresh, email_verified: true, sub: sub) }.to change(Account, :count).by(1)
      expect(StandardId::EmailIdentifier.find_by(value: fresh).provider).to eq("org_idp")
    end
  end
end
