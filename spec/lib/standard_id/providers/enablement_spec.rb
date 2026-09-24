require "rails_helper"

RSpec.describe StandardId::Providers::Base, "enablement and configuration checks" do
  # Field names are unique to this file so declaring them on the global schema
  # cannot collide with a real provider's fields.
  let(:provider) do
    Class.new(described_class) do
      def self.provider_name = "enablement_probe"

      def self.config_schema
        {
          enablement_probe_client_id: { type: :string, default: nil },
          enablement_probe_mobile_client_id: { type: :string, default: nil },
          enablement_probe_secret: { type: :string, default: nil, required: true },
          enablement_probe_team: { type: :string, default: nil, required: true }
        }
      end
    end
  end

  before do
    StandardId::ProviderRegistry.declare_config_schema(provider)
  end

  def set(field, value)
    StandardId.config.social[field] = value
  end

  describe ".enabling_config_field" do
    it "defaults to <provider_name>_client_id when declared" do
      expect(provider.enabling_config_field).to eq(:enablement_probe_client_id)
    end

    it "is nil when the provider declares no such field" do
      bare = Class.new(described_class) { def self.provider_name = "bare_probe" }

      expect(bare.enabling_config_field).to be_nil
      expect(bare).to be_enabled
      expect(bare.configuration_errors).to eq([])
    end
  end

  describe ".required_config_fields" do
    it "lists the fields declared required: true" do
      expect(provider.required_config_fields).to eq(%i[enablement_probe_secret enablement_probe_team])
    end
  end

  describe ".enabled?" do
    it "is false until the enabling field is set" do
      expect(provider).not_to be_enabled
    end

    it "is true once the enabling field is set, whatever else is missing" do
      set(:enablement_probe_client_id, "cid")

      expect(provider).to be_enabled
    end

    it "is not switched on by a non-enabling field alone" do
      set(:enablement_probe_mobile_client_id, "mobile")

      expect(provider).not_to be_enabled
    end
  end

  describe ".configuration_errors" do
    it "is empty while the provider is disabled, even with required fields blank" do
      expect(provider.configuration_errors).to eq([])
    end

    it "names each missing required field once enabled, without values" do
      set(:enablement_probe_client_id, "super-secret-client-id")
      set(:enablement_probe_team, "team")

      expect(provider.configuration_errors).to eq([
        "enablement_probe_secret is required when enablement_probe_client_id is set"
      ])
      expect(provider).not_to be_configured
    end

    it "is empty when every required field is present" do
      set(:enablement_probe_client_id, "cid")
      set(:enablement_probe_secret, "s")
      set(:enablement_probe_team, "t")

      expect(provider.configuration_errors).to eq([])
      expect(provider).to be_configured
    end
  end

  describe "provider-level schema options" do
    it "does not pass required: through to ConfigSchema" do
      field = StandardId::ConfigSchema.instance.field_for(:social, :enablement_probe_secret)

      expect(field).to be_present
      expect(field.type).to eq(:string)
    end
  end

  describe "registry and top-level helpers" do
    around do |example|
      StandardId::ProviderRegistry.register(:enablement_probe, provider)
      example.run
    ensure
      StandardId::ProviderRegistry.providers.delete("enablement_probe")
    end

    it "StandardId.enabled_social_providers includes only enabled providers" do
      expect(StandardId.enabled_social_providers).not_to have_key("enablement_probe")

      set(:enablement_probe_client_id, "cid")

      expect(StandardId.enabled_social_providers["enablement_probe"]).to eq(provider)
    end

    it "StandardId.social_provider_enabled? is false for unregistered providers" do
      expect(StandardId.social_provider_enabled?(:not_installed)).to be(false)
      expect(StandardId.social_provider_enabled?(:enablement_probe)).to be(false)

      set(:enablement_probe_client_id, "cid")

      expect(StandardId.social_provider_enabled?(:enablement_probe)).to be(true)
      expect(StandardId.social_provider_enabled?("enablement_probe")).to be(true)
    end

    describe "ProviderRegistry.validate_configuration!" do
      let(:logger) { instance_double(Logger, warn: nil) }

      it "returns no errors and stays quiet when everything is consistent" do
        expect(StandardId::ProviderRegistry.validate_configuration!(logger:)).to eq({})
        expect(logger).not_to have_received(:warn)
      end

      context "with a partially configured provider" do
        before { set(:enablement_probe_client_id, "cid") }

        it "warns by default" do
          errors = StandardId::ProviderRegistry.validate_configuration!(logger:)

          expect(errors.keys).to eq(["enablement_probe"])
          expect(logger).to have_received(:warn).with(/enablement_probe \(enablement_probe_secret is required/)
        end

        it "only warns outside production when mode is :raise" do
          expect { StandardId::ProviderRegistry.validate_configuration!(mode: :raise, logger:) }.not_to raise_error
          expect(logger).to have_received(:warn)
        end

        it "raises in production when mode is :raise" do
          allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

          expect { StandardId::ProviderRegistry.validate_configuration!(mode: :raise, logger:) }
            .to raise_error(StandardId::ConfigurationError, /enablement_probe_team is required/)
        end

        it "reads the mode from c.social.provider_misconfiguration" do
          allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
          StandardId.config.social.provider_misconfiguration = :raise

          expect { StandardId::ProviderRegistry.validate_configuration!(logger:) }
            .to raise_error(StandardId::ConfigurationError)
        end

        it "only warns in production when mode is :warn" do
          allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

          expect { StandardId::ProviderRegistry.validate_configuration!(mode: :warn, logger:) }.not_to raise_error
          expect(logger).to have_received(:warn)
        end
      end
    end
  end
end
