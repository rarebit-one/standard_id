require "rails_helper"

RSpec.describe StandardId::ProviderRegistry, "ENV defaults for provider config fields" do
  # Unique field names: the schema is process-global and add_field is
  # first-write-wins, so each example group declares its own fields.
  let(:provider) do
    Class.new(StandardId::Providers::Base) do
      def self.provider_name = "envprobe"

      def self.config_schema
        {
          envprobe_client_id: { type: :string, default: nil },
          envprobe_private_key: { type: :string, default: "fallback-key" },
          envprobe_region: { type: :string, default: -> { "computed-region" }, env: "ENVPROBE_CUSTOM_REGION" },
          envprobe_debug_host: { type: :string, default: nil, env: false }
        }
      end
    end
  end

  around do |example|
    keys = %w[ENVPROBE_CLIENT_ID ENVPROBE_PRIVATE_KEY ENVPROBE_REGION ENVPROBE_CUSTOM_REGION ENVPROBE_DEBUG_HOST]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  before { described_class.declare_config_schema(provider) }

  def social = StandardId.config.social

  describe ".env_var_for" do
    it "upper-cases the field name by default" do
      expect(described_class.env_var_for(:apple_private_key)).to eq("APPLE_PRIVATE_KEY")
    end

    it "honours an explicit env: name" do
      expect(described_class.env_var_for(:apple_private_key, env: "APPLE_PRIVATE_KEY_PEM")).to eq("APPLE_PRIVATE_KEY_PEM")
    end

    it "is nil when opted out" do
      expect(described_class.env_var_for(:x, env: false)).to be_nil
    end
  end

  it "falls back to the canonical ENV variable when the field is never assigned" do
    ENV["ENVPROBE_CLIENT_ID"] = "from-env"

    expect(social.envprobe_client_id).to eq("from-env")
    expect(StandardId.config.envprobe_client_id).to eq("from-env")
  end

  it "uses the field's own default when ENV is unset or blank" do
    ENV["ENVPROBE_PRIVATE_KEY"] = ""

    expect(social.envprobe_client_id).to be_nil
    expect(social.envprobe_private_key).to eq("fallback-key")
  end

  it "reads a custom env: name, then a callable default" do
    ENV["ENVPROBE_REGION"] = "ignored"
    expect(social.envprobe_region).to eq("computed-region")

    ENV["ENVPROBE_CUSTOM_REGION"] = "custom"
    expect(social.envprobe_region).to eq("custom")
  end

  it "does not read ENV for fields declared env: false" do
    ENV["ENVPROBE_DEBUG_HOST"] = "should-not-be-used"

    expect(social.envprobe_debug_host).to be_nil
  end

  it "lets explicit configuration win, including an explicit nil" do
    ENV["ENVPROBE_CLIENT_ID"] = "from-env"

    social.envprobe_client_id = "explicit"
    expect(social.envprobe_client_id).to eq("explicit")

    social.envprobe_client_id = nil
    expect(social.envprobe_client_id).to be_nil
  end

  it "feeds enabled? so a provider switches on from ENV alone" do
    expect(provider).not_to be_enabled

    ENV["ENVPROBE_CLIENT_ID"] = "from-env"

    expect(provider).to be_enabled
  end

  it "applies the ENV value when the config is (re)built" do
    ENV["ENVPROBE_CLIENT_ID"] = "at-build"

    config = StandardId::ConfigSchema.build

    expect(config.social.envprobe_client_id).to eq("at-build")
  end
end
