require "rails_helper"

RSpec.describe StandardId do
  describe ".configure" do
    it "yields the static provider for backward compatibility" do
      StandardId.configure do |config|
        config.account_class_name = "Account"
        config.web_layout = "custom"
      end

      expect(StandardId.config.account_class_name).to eq("Account")
      expect(StandardId.config.web_layout).to eq("custom")
    end

    it "configures inertia settings" do
      StandardId.configure do |config|
        config.use_inertia = true
        config.inertia_component_namespace = "Auth"
      end

      expect(StandardId.config.use_inertia).to eq(true)
      expect(StandardId.config.inertia_component_namespace).to eq("Auth")
    end
  end

  describe ".config" do
    it "returns the configuration object" do
      expect(StandardId.config).to be_a(StandardId::ConfigSchema::Config)
    end

    it "returns the same instance on multiple calls" do
      config1 = StandardId.config
      config2 = StandardId.config
      expect(config1).to be(config2)
    end
  end

  describe "integration with existing configuration patterns" do
    context "static configuration (backward compatibility)" do
      before do
        reset_standard_id_cache_store!
        reset_standard_id_logger!

        StandardId.configure do |config|
          config.account_class_name = "Account"
          config.cache_store = "test_cache"
          config.logger = 'test_logger'
        end
      end

      it "maintains existing configuration interface" do
        expect(StandardId.config.account_class_name).to eq("Account")
        expect(StandardId.config.cache_store).to eq("test_cache")
        expect(StandardId.config.logger).to eq("test_logger")
      end

      it "works with cache_store and logger helpers" do
        allow(Rails).to receive(:cache).and_return("rails_cache")
        allow(Rails).to receive(:logger).and_return("rails_logger")

        expect(StandardId.cache_store).to eq("test_cache")
        expect(StandardId.logger).to eq("test_logger")
      end
    end

    context "dynamic configuration with multitenancy" do
      # These examples mutate static config (issuer, login_url) and register a
      # resolver on the :social scope. No hand-rolled save/restore is needed —
      # spec/support/config_isolation.rb snapshots and restores the whole
      # config tree (values + scope resolvers) around every example.

      let(:tenant_configs) do
        {
          "tenant_1" => {
            issuer: "https://tenant1.auth.com",
            login_url: "/tenant1/login",
            google_client_id: "tenant1_google_id"
          },
          "tenant_2" => {
            issuer: "https://tenant2.auth.com",
            login_url: "/tenant2/login",
            google_client_id: "tenant2_google_id"
          }
        }
      end

      let(:current_tenant) { "tenant_1" }

      it "returns tenant-specific configuration" do
        # Configure static settings for tenant_1
        StandardId.configure do |config|
          config.issuer = tenant_configs.dig(current_tenant, :issuer)
          config.login_url = tenant_configs.dig(current_tenant, :login_url)
        end

        # Register dynamic social provider
        StandardId.register(:social, -> { tenant_configs[current_tenant] })

        expect(StandardId.config.issuer).to eq("https://tenant1.auth.com")
        expect(StandardId.config.login_url).to eq("/tenant1/login")
        expect(StandardId.config.google_client_id).to eq("tenant1_google_id")
      end

      it "allows setting tenant-specific configuration" do
        # Simulate adding a new dynamic key using a hash-like provider that reflects updates
        StandardId.register(:social, -> { tenant_configs[current_tenant] })
        tenant_configs["tenant_1"][:apple_client_id] = "tenant1_apple_id"
        expect(StandardId.config.apple_client_id).to eq("tenant1_apple_id")
      end

      it "switches context when tenant changes" do
        # Swap behavior by updating the underlying dynamic object
        StandardId.configure do |c|
          c.issuer = tenant_configs.dig("tenant_2", :issuer)
          c.login_url = tenant_configs.dig("tenant_2", :login_url)
        end
        expect(StandardId.config.issuer).to eq("https://tenant2.auth.com")
        expect(StandardId.config.login_url).to eq("/tenant2/login")
      end

      it "maintains static configuration across tenants" do
        expect(StandardId.config.account_class_name).to eq("Account")
      end
    end
  end
end
