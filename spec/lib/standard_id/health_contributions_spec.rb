require "rails_helper"

# standard_health is not in this bundle, so the hook is exercised the way
# standard_health fires it: run_load_hooks(:standard_health, registry). The
# fake records calls through the only two methods the real registry exposes,
# so the hook calling anything else fails with NoMethodError.
RSpec.describe "StandardId's standard_health load hook" do
  let(:env_spec_dsl) do
    Class.new do
      attr_reader :entries

      def initialize
        @entries = []
      end

      def recommended(name, **options) = @entries << [:recommended, name, options]
      def forbidden(name, **options) = @entries << [:forbidden, name, options]
    end
  end

  let(:registry) do
    dsl_class = env_spec_dsl
    Class.new do
      attr_reader :checks, :env_vars

      define_method(:initialize) do
        @checks = []
        @env_vars = {}
        @dsl_class = dsl_class
      end

      def contribute_check(name, klass, **options)
        @checks << [name, klass, options]
      end

      def contribute_env_vars(contributor, &block)
        @env_vars[contributor] = @dsl_class.new.tap { |dsl| dsl.instance_eval(&block) }.entries
      end
    end.new
  end

  before { ActiveSupport.run_load_hooks(:standard_health, registry) }

  # run_load_hooks remembers its base so later on_load calls fire on it; drop
  # the fake so it cannot reach another example.
  after { ActiveSupport.instance_variable_get(:@loaded)[:standard_health]&.delete(registry) }

  it "contributes the migrations check, non-critical, by class name" do
    expect(registry.checks).to eq([[:standard_id_migrations, "StandardId::Checks::Migrations", { critical: false }]])
  end

  it "names a class that exists and fits standard_health's check contract" do
    klass = registry.checks.first[1].constantize
    check = klass.new(name: :standard_id_migrations, critical: false)

    expect(check).to respond_to(:run)
    expect(check.critical?).to be(false)
  end

  it "declares the env vars under the standard_id contributor" do
    expect(registry.env_vars.keys).to eq(["standard_id"])
    expect(registry.env_vars["standard_id"].map { |level, name, _| [level, name] }).to eq(
      [%i[recommended APP_ENVIRONMENT], %i[forbidden STANDARD_ID_BYPASS_CODE]]
    )
  end

  it "forbids the bypass code in production only, with plain environment names" do
    _, _, options = registry.env_vars["standard_id"].find { |_, name, _| name == :STANDARD_ID_BYPASS_CODE }

    expect(options[:in]).to eq(%w[production])
  end

  it "describes every env var" do
    expect(registry.env_vars["standard_id"].map { |_, _, options| options[:description] }).to all(be_present)
  end
end
