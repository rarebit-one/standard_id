require "rails_helper"

RSpec.describe StandardId::Config::ScopeClaimsValidator do
  around do |example|
    original_scope_claims = StandardId.config.oauth.scope_claims
    original_resolvers = StandardId.config.oauth.claim_resolvers
    example.run
  ensure
    StandardId.config.oauth.scope_claims = original_scope_claims
    StandardId.config.oauth.claim_resolvers = original_resolvers
  end

  describe ".validate!" do
    it "passes when scope_claims is empty" do
      StandardId.config.oauth.scope_claims = {}
      expect { described_class.validate! }.not_to raise_error
    end

    it "passes when every claim has a resolver" do
      StandardId.config.oauth.scope_claims = { "profile" => %w[name email] }
      StandardId.config.oauth.claim_resolvers = {
        "name"  => ->(account:, **) { account&.name },
        "email" => ->(account:, **) { account&.email }
      }
      expect { described_class.validate! }.not_to raise_error
    end

    it "tolerates symbol/string key mixing across the two hashes" do
      StandardId.config.oauth.scope_claims = { profile: [:name] }
      StandardId.config.oauth.claim_resolvers = { "name" => ->(**) { "x" } }
      expect { described_class.validate! }.not_to raise_error
    end

    it "accepts a single claim declared as a string (not an array)" do
      StandardId.config.oauth.scope_claims = { "profile" => "name" }
      StandardId.config.oauth.claim_resolvers = { "name" => ->(**) { "x" } }
      expect { described_class.validate! }.not_to raise_error
    end

    it "raises when a claim has no resolver, naming the scope and claim" do
      StandardId.config.oauth.scope_claims = { "profile" => %w[name email] }
      StandardId.config.oauth.claim_resolvers = { "name" => ->(**) { "x" } }
      expect { described_class.validate! }.to raise_error(
        StandardId::ConfigurationError,
        /scope_claims.*no resolver.*profile -> \["email"\]/
      )
    end

    it "aggregates missing claims across multiple scopes in the error" do
      StandardId.config.oauth.scope_claims = {
        "profile" => %w[name],
        "billing" => %w[plan]
      }
      StandardId.config.oauth.claim_resolvers = {}
      expect { described_class.validate! }.to raise_error(StandardId::ConfigurationError) do |e|
        expect(e.message).to include("profile")
        expect(e.message).to include("billing")
        expect(e.message).to include("name")
        expect(e.message).to include("plan")
      end
    end
  end
end
