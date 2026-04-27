require "rails_helper"

RSpec.describe StandardId::ProviderRegistry do
  let(:test_provider_class) do
    Class.new(StandardId::Providers::Base) do
      class << self
        def provider_name
          "test_provider"
        end

        def authorization_url(state:, redirect_uri:, **options)
          "https://test.example.com/auth?state=#{state}&redirect_uri=#{redirect_uri}"
        end

        def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, **options)
          {
            user_info: { "sub" => "test_user_123", "email" => "test@example.com" },
            tokens: { access_token: "test_token" }
          }.with_indifferent_access
        end

        def config_schema
          {
            test_client_id: { type: :string, default: nil },
            test_client_secret: { type: :string, default: nil }
          }
        end
      end
    end
  end

  before(:all) do
    @original_providers = described_class.all.dup
  end

  after do
    described_class.instance_variable_set(:@providers, @original_providers.dup)
  end

  describe ".register" do
    it "registers a valid provider" do
      result = described_class.register(:test, test_provider_class)

      expect(result).to eq(test_provider_class)
      expect(described_class.registered?(:test)).to be true
    end

    it "calls setup on the provider if defined" do
      setup_called = false
      provider_with_setup = Class.new(StandardId::Providers::Base) do
        define_singleton_method(:provider_name) { "setup_test" }
        define_singleton_method(:authorization_url) { |**| "url" }
        define_singleton_method(:get_user_info) { |**| {} }
        define_singleton_method(:setup) { setup_called = true }
      end

      described_class.register(:setup_test, provider_with_setup)

      expect(setup_called).to be true
    end

    it "registers config_schema fields with the StandardId schema" do
      described_class.register(:test, test_provider_class)

      expect(StandardId::ConfigSchema.instance.field?(:social, :test_client_id)).to be true
      expect(StandardId::ConfigSchema.instance.field?(:social, :test_client_secret)).to be true
    end

    it "skips config registration when config_schema is empty" do
      provider_without_config = Class.new(StandardId::Providers::Base) do
        define_singleton_method(:provider_name) { "no_config" }
        define_singleton_method(:authorization_url) { |**| "url" }
        define_singleton_method(:get_user_info) { |**| {} }
      end

      expect {
        described_class.register(:no_config, provider_without_config)
      }.not_to raise_error
    end

    context "with invalid provider class" do
      it "raises InvalidProviderError for non-class" do
        expect {
          described_class.register(:invalid, "not a class")
        }.to raise_error(StandardId::ProviderRegistry::InvalidProviderError, /must be a class/)
      end

      it "raises InvalidProviderError for class not inheriting from Base" do
        invalid_class = Class.new

        expect {
          described_class.register(:invalid, invalid_class)
        }.to raise_error(StandardId::ProviderRegistry::InvalidProviderError, /must inherit from/)
      end
    end
  end

  describe ".get" do
    before do
      described_class.register(:test, test_provider_class)
    end

    it "returns the registered provider" do
      provider = described_class.get(:test)

      expect(provider).to eq(test_provider_class)
    end

    it "accepts string provider names" do
      provider = described_class.get("test")

      expect(provider).to eq(test_provider_class)
    end

    it "raises ProviderNotFoundError for unregistered provider" do
      expect {
        described_class.get(:unknown)
      }.to raise_error(StandardId::ProviderRegistry::ProviderNotFoundError, /Unknown provider: unknown/)
    end

    it "includes available providers in error message" do
      expect {
        described_class.get(:unknown)
      }.to raise_error(/Available providers:.*test/)
    end
  end

  describe ".all" do
    before do
      described_class.register(:test, test_provider_class)
    end

    it "returns all registered providers" do
      providers = described_class.all

      expect(providers).to include("test" => test_provider_class)
    end

    it "returns a duplicate hash (not the internal hash)" do
      providers = described_class.all
      providers["modified"] = "test"

      expect(described_class.all).not_to include("modified")
    end
  end

  describe ".registered?" do
    before do
      described_class.register(:test, test_provider_class)
    end

    it "returns true for registered provider" do
      expect(described_class.registered?(:test)).to be true
    end

    it "returns false for unregistered provider" do
      expect(described_class.registered?(:unknown)).to be false
    end

    it "handles string names" do
      expect(described_class.registered?("test")).to be true
    end
  end
end
