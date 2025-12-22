require "rails_helper"
require "concurrent-ruby"

RSpec.describe StandardId, "thread safety" do
  describe ".cache_store" do
    before { reset_standard_id_cache_store! }
    after { reset_standard_id_cache_store! }

    it "returns the same value when accessed concurrently" do
      allow(Rails).to receive(:cache).and_return(:rails_cache)

      config_double = double("Config", cache_store: nil, logger: nil)
      allow(described_class).to receive(:config).and_return(config_double)

      promises = Array.new(20) { Concurrent::Promise.execute { described_class.cache_store } }
      values = promises.map(&:value)

      expect(values).to all(eq(:rails_cache))
    end

    it "resolves the cache store value only once under concurrent access" do
      resolve_count = Concurrent::AtomicFixnum.new(0)

      config_double = double("Config", logger: nil)
      allow(config_double).to receive(:cache_store) do
        resolve_count.increment
        sleep(0.01) # Simulate slow resolution to increase race window
        :configured_cache
      end
      allow(described_class).to receive(:config).and_return(config_double)

      # Use a latch to ensure all threads start simultaneously
      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do
        Concurrent::Promise.execute do
          latch.wait
          described_class.cache_store
        end
      end

      latch.count_down
      values = promises.map(&:value)

      expect(values).to all(eq(:configured_cache))
      expect(resolve_count.value).to eq(1)
    end
  end

  describe ".logger" do
    before { reset_standard_id_logger! }
    after { reset_standard_id_logger! }

    it "returns the same value when accessed concurrently" do
      allow(Rails).to receive(:logger).and_return(:rails_logger)

      config_double = double("Config", cache_store: nil, logger: nil)
      allow(described_class).to receive(:config).and_return(config_double)

      promises = Array.new(20) { Concurrent::Promise.execute { described_class.logger } }
      values = promises.map(&:value)

      expect(values).to all(eq(:rails_logger))
    end

    it "resolves the logger value only once under concurrent access" do
      resolve_count = Concurrent::AtomicFixnum.new(0)

      config_double = double("Config", cache_store: nil)
      allow(config_double).to receive(:logger) do
        resolve_count.increment
        sleep(0.01)
        :configured_logger
      end
      allow(described_class).to receive(:config).and_return(config_double)

      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do
        Concurrent::Promise.execute do
          latch.wait
          described_class.logger
        end
      end

      latch.count_down
      values = promises.map(&:value)

      expect(values).to all(eq(:configured_logger))
      expect(resolve_count.value).to eq(1)
    end
  end
end
