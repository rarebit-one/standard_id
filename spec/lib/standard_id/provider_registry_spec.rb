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

  describe ".declare_config_schemas!" do
    # The schema is process-global and, unlike StandardId.config, is not
    # snapshotted by the config-isolation hook. Clean up the fields these
    # examples declare so they don't leak into later examples.
    after do
      social = StandardId::ConfigSchema.instance.scopes[:social]
      %i[eager_client_id eager_client_secret].each { |f| social&.delete(f) }
    end

    it "declares the fields of a LOADED but UNREGISTERED provider" do
      klass = test_provider_class # forces the anonymous subclass to exist
      allow(described_class).to receive(:provider_classes).and_return([klass])

      described_class.declare_config_schemas!

      expect(described_class.registered?(:test)).to be false
      expect(StandardId::ConfigSchema.instance.field?(:social, :test_client_id)).to be true
    end

    it "does not register the providers, run setup, or validate them" do
      setup_called = false
      klass = Class.new(StandardId::Providers::Base) do
        define_singleton_method(:provider_name) { "eager" }
        define_singleton_method(:authorization_url) { |**| "url" }
        define_singleton_method(:get_user_info) { |**| {} }
        define_singleton_method(:setup) { setup_called = true }
        define_singleton_method(:config_schema) { { eager_client_id: { type: :string, default: nil } } }
      end
      allow(described_class).to receive(:provider_classes).and_return([klass])

      described_class.declare_config_schemas!

      expect(setup_called).to be false
      expect(described_class.all.values).not_to include(klass)
      expect(StandardId::ConfigSchema.instance.field?(:social, :eager_client_id)).to be true
    end

    it "is idempotent and does not clobber a value the host already wrote" do
      klass = Class.new(StandardId::Providers::Base) do
        define_singleton_method(:provider_name) { "eager" }
        define_singleton_method(:authorization_url) { |**| "url" }
        define_singleton_method(:get_user_info) { |**| {} }
        define_singleton_method(:config_schema) { { eager_client_id: { type: :string, default: "from-schema" } } }
      end
      allow(described_class).to receive(:provider_classes).and_return([klass])

      described_class.declare_config_schemas!
      StandardId.config.social.eager_client_id = "set-by-host"
      described_class.declare_config_schemas!

      expect(StandardId.config.social.eager_client_id).to eq("set-by-host")
    end

    it "tolerates a provider whose config_schema is empty" do
      klass = Class.new(StandardId::Providers::Base) do
        define_singleton_method(:provider_name) { "bare" }
        define_singleton_method(:authorization_url) { |**| "url" }
        define_singleton_method(:get_user_info) { |**| {} }
      end
      allow(described_class).to receive(:provider_classes).and_return([klass])

      expect { described_class.declare_config_schemas! }.not_to raise_error
    end
  end

  describe ".provider_classes" do
    it "includes loaded subclasses of Providers::Base" do
      klass = test_provider_class

      expect(described_class.provider_classes).to include(klass)
    end

    it "includes already-registered classes even when not direct subclasses" do
      grandchild = Class.new(test_provider_class)
      described_class.register(:grandchild, grandchild)

      expect(described_class.provider_classes).to include(grandchild)
      expect(StandardId::Providers::Base.subclasses).not_to include(grandchild)
    end
  end

  # This is the property that makes the fix backward-compatible: consuming apps
  # already wrap their provider config in
  # `Rails.application.config.after_initialize { ... }` to work around the boot
  # order. Those wrappers must keep working verbatim, which they do only because
  # declaring a field LATER is indistinguishable from declaring it earlier.
  describe "add_field retroactivity (why existing after_initialize wrappers keep working)" do
    after do
      StandardId::ConfigSchema.instance.scopes[:social]&.delete(:retro_client_id)
    end

    it "permits writes and reads for a field declared after the config was built" do
      expect(StandardId.config.social).to be_a(StandardId::ConfigSchema::Scope)

      expect {
        StandardId.config.social.retro_client_id = "nope"
      }.to raise_error(StandardId::ConfigurationError, /Unknown field 'retro_client_id'/)

      StandardId::ConfigSchema.add_field(scope: :social, name: :retro_client_id, type: :string, default: "fallback")

      expect(StandardId.config.social.retro_client_id).to eq("fallback")
      expect { StandardId.config.social.retro_client_id = "written" }.not_to raise_error
      expect(StandardId.config.social.retro_client_id).to eq("written")
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
