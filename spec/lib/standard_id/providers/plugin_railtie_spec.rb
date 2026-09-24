require "rails_helper"

RSpec.describe StandardId::Providers, ".plugin_railtie" do
  let(:provider_class) do
    Class.new(StandardId::Providers::Base) do
      def self.provider_name = "railtie_probe"
    end
  end

  after do
    StandardId::ProviderRegistry.providers.delete("railtie_probe")
    if StandardId::Providers::Railties.const_defined?(:RailtieProbe, false)
      StandardId::Providers::Railties.send(:remove_const, :RailtieProbe)
    end
  end

  it "defines a named Rails::Railtie under Providers::Railties" do
    railtie = described_class.plugin_railtie(:railtie_probe, provider_class)

    expect(railtie).to be < Rails::Railtie
    expect(railtie.name).to eq("StandardId::Providers::Railties::RailtieProbe")
  end

  it "registers the provider from after_initialize" do
    # The dummy app has already initialized, so ActiveSupport runs a newly
    # added after_initialize hook immediately — the same code path a plugin's
    # hook takes at the end of a real boot.
    described_class.plugin_railtie(:railtie_probe, provider_class)

    expect(StandardId::ProviderRegistry.get(:railtie_probe)).to eq(provider_class)
  end

  it "accepts the provider class by name and constantizes it lazily" do
    stub_const("RailtieProbeProvider", provider_class)

    described_class.plugin_railtie(:railtie_probe, "RailtieProbeProvider")

    expect(StandardId::ProviderRegistry.get(:railtie_probe)).to eq(provider_class)
  end

  it "is idempotent per provider name" do
    first = described_class.plugin_railtie(:railtie_probe, provider_class)

    expect(described_class.plugin_railtie(:railtie_probe, provider_class)).to equal(first)
  end
end
