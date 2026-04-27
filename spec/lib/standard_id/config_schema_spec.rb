require "rails_helper"
require "concurrent-ruby"

RSpec.describe StandardId::ConfigSchema do
  let(:schema) { described_class.new }

  describe "#define" do
    it "registers scopes and fields via the DSL" do
      schema.define do
        scope :base do
          field :account_class_name, type: :string, default: "User"
        end
        scope :passwordless do
          field :code_ttl, type: :integer, default: 600
          field :enabled, type: :boolean, default: false
        end
      end

      expect(schema.scope?(:base)).to be true
      expect(schema.field?(:passwordless, :code_ttl)).to be true
      expect(schema.field_for(:passwordless, :code_ttl).default).to eq(600)
    end
  end

  describe "#apply" do
    let(:config) { described_class::Config.new }

    before do
      schema.define do
        scope :base do
          field :account_class_name, type: :string, default: "User"
          field :allowed, type: :array, default: []
        end
        scope :passwordless do
          field :code_ttl, type: :integer, default: 600
        end
      end
      schema.apply(config)
    end

    it "populates defaults under nested scopes" do
      expect(config.passwordless.code_ttl).to eq(600)
      expect(config.base.account_class_name).to eq("User")
    end

    it "routes unique field names to their owning scope at the top level" do
      expect(config.account_class_name).to eq("User")
      expect(config.code_ttl).to eq(600)
    end

    it "writes via top-level routing for unique field names" do
      config.account_class_name = "Account"
      expect(config.base.account_class_name).to eq("Account")
    end

    it "returns nil for ambiguous field names present in multiple scopes" do
      ambiguous_schema = described_class.new
      ambiguous_schema.define do
        scope :a do
          field :delivery, type: :string, default: "from_a"
        end
        scope :b do
          field :delivery, type: :string, default: "from_b"
        end
      end
      ambiguous = described_class::Config.new
      ambiguous_schema.apply(ambiguous)
      # `delivery` exists in both :a and :b — top-level access intentionally
      # returns nil rather than guessing or raising. Callers must use the scope.
      expect(ambiguous.delivery).to be_nil
      expect(ambiguous.a.delivery).to eq("from_a")
      expect(ambiguous.b.delivery).to eq("from_b")
    end

    it "dups Array/Hash defaults so callers cannot mutate the schema" do
      first = config.allowed
      first << :leak
      expect(config.allowed).to eq([])
    end
  end

  describe "type casting" do
    let(:config) { described_class::Config.new }

    before do
      schema.define do
        scope :test do
          field :as_int, type: :integer
          field :as_float, type: :float
          field :as_bool, type: :boolean
          field :as_string, type: :string
          field :as_array, type: :array
          field :as_hash, type: :hash
          field :as_symbol, type: :symbol
          field :as_any, type: :any
        end
      end
      schema.apply(config)
    end

    it "casts according to declared type" do
      config.test.as_int = "42"
      config.test.as_float = "1.5"
      config.test.as_bool = "true"
      config.test.as_string = 99
      config.test.as_array = "x"
      config.test.as_hash = nil
      config.test.as_symbol = :foo
      config.test.as_any = { mixed: 1 }

      expect(config.test.as_int).to eq(42)
      expect(config.test.as_float).to eq(1.5)
      expect(config.test.as_bool).to be true
      expect(config.test.as_string).to eq("99")
      expect(config.test.as_array).to eq(["x"])
      expect(config.test.as_hash).to eq(nil) # cast preserves nil
      expect(config.test.as_symbol).to eq(:foo)
      expect(config.test.as_any).to eq(mixed: 1)
    end

    it "casts strings to symbols for :symbol type" do
      config.test.as_symbol = "from_string"
      expect(config.test.as_symbol).to eq(:from_string)
    end
  end

  describe "validation" do
    let(:config) { described_class::Config.new }

    before do
      schema.define do
        scope :base do
          field :name, type: :string
        end
      end
      schema.apply(config)
    end

    it "raises for unknown writes" do
      expect { config.base[:bogus] = 1 }
        .to raise_error(StandardId::ConfigurationError, /Unknown field 'bogus'/)
    end

    it "raises for unknown reads" do
      expect { config.base[:bogus] }
        .to raise_error(StandardId::ConfigurationError, /Unknown field 'bogus'/)
    end
  end

  describe "#add_field (dynamic)" do
    let(:config) { described_class::Config.new }

    before do
      schema.define { scope :social }
      schema.apply(config)
    end

    it "adds a field after schema is built" do
      schema.add_field(scope: :social, name: :provider_client_id, type: :string, default: nil)
      config.social.provider_client_id = "abc"
      expect(config.social.provider_client_id).to eq("abc")
    end

    it "is idempotent — adding the same field twice keeps the first definition" do
      schema.add_field(scope: :social, name: :token, type: :string, default: "first")
      schema.add_field(scope: :social, name: :token, type: :integer, default: 999)
      expect(schema.field_for(:social, :token).default).to eq("first")
    end
  end

  describe "thread safety" do
    it "creates each scope exactly once under concurrent access" do
      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do |i|
        Concurrent::Promise.execute do
          latch.wait
          schema.add_field(scope: :shared, name: :"f_#{i}", type: :string)
        end
      end

      latch.count_down
      promises.each(&:wait)

      expect(schema.scopes.keys).to eq([:shared])
      expect(schema.scopes[:shared].size).to eq(20)
    end

    it "handles concurrent add_field calls for the same field name idempotently" do
      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do
        Concurrent::Promise.execute do
          latch.wait
          schema.add_field(scope: :s, name: :same, type: :string, default: "x")
        end
      end

      latch.count_down
      promises.each(&:wait)

      expect(schema.scopes[:s].size).to eq(1)
      expect(schema.field_for(:s, :same).default).to eq("x")
    end
  end

  describe "Config#register (resolver-backed scope)" do
    let(:config) { described_class::Config.new }

    before do
      schema.define do
        scope :social do
          field :client_id, type: :string, default: nil
          field :client_secret, type: :string, default: nil
        end
      end
      schema.apply(config)
    end

    it "delegates reads to the resolver-returned hash" do
      tenant = { client_id: "abc", client_secret: "secret" }
      config.register(:social, -> { tenant })

      expect(config.social.client_id).to eq("abc")
      expect(config.client_id).to eq("abc")
    end

    it "reflects updates to the underlying hash on subsequent reads" do
      tenant = { client_id: "v1" }
      config.register(:social, -> { tenant })
      expect(config.client_id).to eq("v1")

      tenant[:client_id] = "v2"
      expect(config.client_id).to eq("v2")
    end

    it "rejects unknown scopes" do
      expect { config.register(:nope, -> { {} }) }
        .to raise_error(ArgumentError, /Unknown configuration scope/)
    end
  end
end
