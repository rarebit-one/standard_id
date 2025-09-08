require "spec_helper"
require "standard_config"

RSpec.describe StandardConfig::ConfigProvider do
  before(:all) do
    # Reset and define a minimal schema for these tests
    StandardConfig.instance_variable_set(:@schema, StandardConfig::Schema.new)
    StandardConfig.schema.draw do
      scope :passwordless do
        field :code_ttl, type: :integer, default: 600
        field :max_attempts, type: :integer, default: 3
        field :retry_delay, type: :integer, default: 30
      end
      scope :oauth do
        field :default_token_lifetime, type: :integer, default: 3600
        field :refresh_token_lifetime, type: :integer, default: 2592000
        field :client_id, type: :string, default: nil
        field :client_secret, type: :string, default: nil
      end
    end
  end

  let(:scope_name) { :passwordless }
  let(:resolver) do
    obj = OpenStruct.new(code_ttl: 600, max_attempts: 3, retry_delay: 30)
    -> { obj }
  end

  subject(:provider) { described_class.new(scope_name, resolver, StandardConfig.schema) }

  describe "get_field" do
    it "returns a cast value based on schema" do
      expect(provider.get_field(:code_ttl)).to be_a(Integer)
      expect(provider.get_field(:code_ttl)).to eq(600)
    end

    it "dups arrays and hashes to prevent mutation of defaults" do
      scope = :oauth
      resolver2 = -> { OpenStruct.new(default_token_lifetime: 3600, refresh_token_lifetime: 2592000, client_id: "x", client_secret: "y") }
      p2 = described_class.new(scope, resolver2, StandardConfig.schema)
      expect(p2.get_field(:default_token_lifetime)).to eq(3600)
    end

    it "raises for unknown fields" do
      expect { provider.get_field(:unknown_key) }.to raise_error(ArgumentError)
    end
  end

  describe "setters" do
    it "sets values on OpenStruct for valid fields" do
      provider.public_send(:code_ttl=, 1200)
      expect(provider.get_field(:code_ttl)).to eq(1200)
    end

    it "raises for setting unknown field" do
      expect { provider.public_send(:unknown=, 1) }.to raise_error(ArgumentError)
    end
  end
end
