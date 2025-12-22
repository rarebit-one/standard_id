require "spec_helper"
require "standard_config"
require "concurrent-ruby"

RSpec.describe StandardConfig, "thread safety" do
  describe "Schema" do
    it "creates each scope exactly once under concurrent access" do
      schema = StandardConfig::Schema.new
      creation_counts = Concurrent::Map.new

      # Monkey-patch ScopeBuilder to track creations
      original_new = StandardConfig::Schema::ScopeBuilder.method(:new)
      allow(StandardConfig::Schema::ScopeBuilder).to receive(:new) do |name|
        creation_counts.compute(name) { |v| (v || 0) + 1 }
        original_new.call(name)
      end

      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do |i|
        Concurrent::Promise.execute do
          latch.wait
          schema.scope("shared_scope".to_sym) do
            field "field_#{i}".to_sym, type: :string
          end
        end
      end

      latch.count_down
      promises.each(&:wait)

      expect(schema.scopes.size).to eq(1)
      expect(creation_counts[:shared_scope]).to eq(1)
    end

    it "safely handles concurrent field additions to the same scope" do
      schema = StandardConfig::Schema.new
      schema.scope(:concurrent_fields)

      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do |i|
        Concurrent::Promise.execute do
          latch.wait
          schema.scopes[:concurrent_fields].field("field_#{i}".to_sym, type: :string)
        end
      end

      latch.count_down
      promises.each(&:wait)

      expect(schema.scopes[:concurrent_fields].fields.size).to eq(20)
    end
  end

  describe "Manager" do
    let(:schema) do
      StandardConfig::Schema.new.tap do |s|
        s.scope(:test) do
          field :test_field, type: :string, default: "default"
        end
      end
    end

    it "creates static config exactly once under concurrent access" do
      manager = StandardConfig::Manager.new(schema)
      creation_count = Concurrent::AtomicFixnum.new(0)

      # Track static config creation
      allow(OpenStruct).to receive(:new).and_wrap_original do |original_method, *args|
        creation_count.increment
        original_method.call(*args)
      end

      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do
        Concurrent::Promise.execute do
          latch.wait
          manager.test_field
        end
      end

      latch.count_down
      values = promises.map(&:value)

      expect(values).to all(eq("default"))
      expect(creation_count.value).to eq(1)
    end

    it "returns consistent values under concurrent read/write" do
      manager = StandardConfig::Manager.new(schema)

      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do |i|
        Concurrent::Promise.execute do
          latch.wait
          if i.even?
            manager.test_field
          else
            manager.test_field = "new_value"
            manager.test_field
          end
        end
      end

      latch.count_down
      values = promises.map(&:value)

      # All values should be either "default" or "new_value"
      expect(values).to all(satisfy { |v| %w[default new_value].include?(v) })
    end
  end
end
