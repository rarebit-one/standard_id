require "rails_helper"
require "concurrent-ruby"

RSpec.describe StandardId::ProviderRegistry, "thread safety" do
  def create_test_provider(name)
    Class.new(StandardId::Providers::Base) do
      define_singleton_method(:provider_name) { name }
      define_singleton_method(:authorization_url) { |**| "https://#{name}.com/auth" }
      define_singleton_method(:get_user_info) { |**| { user_info: {}, tokens: {} } }
      define_singleton_method(:config_schema) { {} }
    end
  end

  describe ".register" do
    it "safely handles concurrent registration of different providers" do
      providers = Array.new(10) { |i| create_test_provider("thread_test_#{i}") }

      latch = Concurrent::CountDownLatch.new(1)
      promises = providers.map.with_index do |provider_class, i|
        Concurrent::Promise.execute do
          latch.wait
          described_class.register("thread_test_#{i}".to_sym, provider_class)
        end
      end

      latch.count_down
      results = promises.map(&:value)

      expect(results).to all(be_a(Class))
      providers.each_with_index do |_, i|
        expect(described_class.registered?("thread_test_#{i}")).to be true
      end
    end

    it "handles concurrent registration of the same key safely" do
      provider_classes = Array.new(10) { create_test_provider("same_key_test") }

      latch = Concurrent::CountDownLatch.new(1)
      promises = provider_classes.map do |provider_class|
        Concurrent::Promise.execute do
          latch.wait
          described_class.register(:same_key_provider, provider_class)
        end
      end

      latch.count_down
      results = promises.map(&:value)

      # All should succeed (last write wins, but no crashes)
      expect(results).to all(be_a(Class))
      expect(described_class.registered?(:same_key_provider)).to be true
    end
  end

  describe ".get" do
    it "safely handles concurrent get operations" do
      test_provider = create_test_provider("get_test")
      described_class.register(:get_test_provider, test_provider)

      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do
        Concurrent::Promise.execute do
          latch.wait
          described_class.get(:get_test_provider)
        end
      end

      latch.count_down
      results = promises.map(&:value)

      expect(results).to all(eq(test_provider))
    end
  end

  describe ".all" do
    it "returns a consistent snapshot when accessed concurrently" do
      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do
        Concurrent::Promise.execute do
          latch.wait
          described_class.all
        end
      end

      latch.count_down
      results = promises.map(&:value)

      expect(results).to all(be_a(Hash))
      # All snapshots should be consistent (same keys)
      first_keys = results.first.keys.sort
      expect(results.map { |r| r.keys.sort }).to all(eq(first_keys))
    end

    it "returns an independent copy (mutations don't affect internal state)" do
      initial_count = described_class.all.size

      snapshot = described_class.all
      snapshot["fake_provider"] = "should_not_persist"

      expect(described_class.all.size).to eq(initial_count)
      expect(described_class.all).not_to have_key("fake_provider")
    end
  end

  describe ".registered?" do
    it "safely handles concurrent registered? checks" do
      test_provider = create_test_provider("registered_test")
      described_class.register(:registered_test_provider, test_provider)

      latch = Concurrent::CountDownLatch.new(1)
      promises = Array.new(20) do
        Concurrent::Promise.execute do
          latch.wait
          described_class.registered?(:registered_test_provider)
        end
      end

      latch.count_down
      results = promises.map(&:value)

      expect(results).to all(be true)
    end
  end
end
