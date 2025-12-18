require "rails_helper"

RSpec.describe StandardId::Metric do
  describe "validations" do
    it "requires name" do
      metric = described_class.new(time_bucket: Time.current, count: 1)
      expect(metric).not_to be_valid
      expect(metric.errors[:name]).to include("can't be blank")
    end

    it "requires time_bucket" do
      metric = described_class.new(name: "auth.attempt", count: 1)
      expect(metric).not_to be_valid
      expect(metric.errors[:time_bucket]).to include("can't be blank")
    end

    it "requires count to be non-negative" do
      metric = described_class.new(name: "auth.attempt", time_bucket: Time.current, count: -1)
      expect(metric).not_to be_valid
      expect(metric.errors[:count]).to include("must be greater than or equal to 0")
    end

    it "validates status inclusion" do
      metric = described_class.new(name: "auth.attempt", time_bucket: Time.current, count: 1, status: "invalid")
      expect(metric).not_to be_valid
      expect(metric.errors[:status]).to include("is not included in the list")
    end

    it "is valid with required attributes" do
      metric = described_class.new(name: "auth.attempt", time_bucket: Time.current, count: 1)
      expect(metric).to be_valid
    end
  end

  describe "scopes" do
    let!(:auth_success) do
      described_class.create!(
        name: "auth.attempt",
        status: "success",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 10
      )
    end

    let!(:auth_failure) do
      described_class.create!(
        name: "auth.attempt",
        status: "failure",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 3
      )
    end

    let!(:session_created) do
      described_class.create!(
        name: "session.created",
        status: "success",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 5
      )
    end

    let!(:yesterday_auth) do
      described_class.create!(
        name: "auth.attempt",
        status: "success",
        dimensions: {},
        time_bucket: 1.day.ago.beginning_of_hour,
        count: 20
      )
    end

    describe ".for_metric" do
      it "filters by metric name" do
        results = described_class.for_metric("auth.attempt")
        expect(results).to include(auth_success, auth_failure, yesterday_auth)
        expect(results).not_to include(session_created)
      end
    end

    describe ".in_time_range" do
      it "filters by time range" do
        range = Time.current.beginning_of_day..Time.current.end_of_day
        results = described_class.in_time_range(range)
        expect(results).to include(auth_success, auth_failure, session_created)
        expect(results).not_to include(yesterday_auth)
      end
    end

    describe ".today" do
      it "returns only today's metrics" do
        results = described_class.today
        expect(results).to include(auth_success, auth_failure, session_created)
        expect(results).not_to include(yesterday_auth)
      end
    end

    describe ".successful" do
      it "returns only successful metrics" do
        results = described_class.successful
        expect(results).to include(auth_success, yesterday_auth, session_created)
        expect(results).not_to include(auth_failure)
      end
    end

    describe ".failed" do
      it "returns only failed metrics" do
        results = described_class.failed
        expect(results).to include(auth_failure)
        expect(results).not_to include(auth_success, session_created, yesterday_auth)
      end
    end
  end

  describe ".increment" do
    it "creates a new metric when none exists" do
      expect {
        described_class.increment(name: "auth.attempt", status: "success")
      }.to change { described_class.count }.by(1)
    end

    it "increments existing metric count" do
      described_class.increment(name: "auth.attempt", status: "success")
      described_class.increment(name: "auth.attempt", status: "success")

      metric = described_class.last
      expect(metric.count).to eq(2)
    end

    it "creates separate metrics for different statuses" do
      described_class.increment(name: "auth.attempt", status: "success")
      described_class.increment(name: "auth.attempt", status: "failure")

      expect(described_class.count).to eq(2)
    end

    it "creates separate metrics for different time buckets" do
      described_class.increment(
        name: "auth.attempt",
        status: "success",
        time_bucket: Time.current.beginning_of_hour
      )
      described_class.increment(
        name: "auth.attempt",
        status: "success",
        time_bucket: 1.hour.ago.beginning_of_hour
      )

      expect(described_class.count).to eq(2)
    end

    it "accumulates duration values" do
      described_class.increment(name: "auth.attempt", status: "success", duration: 50.0)
      described_class.increment(name: "auth.attempt", status: "success", duration: 30.0)

      metric = described_class.last
      expect(metric.total_duration).to eq(80.0)
    end

    it "normalizes dimension keys to strings" do
      described_class.increment(name: "auth.attempt", status: "success", dimensions: { method: "password" })
      described_class.increment(name: "auth.attempt", status: "success", dimensions: { "method" => "password" })

      expect(described_class.count).to eq(1)
      expect(described_class.last.count).to eq(2)
    end

    it "sorts dimensions for consistent hashing" do
      described_class.increment(name: "auth.attempt", status: "success", dimensions: { b: "2", a: "1" })
      described_class.increment(name: "auth.attempt", status: "success", dimensions: { a: "1", b: "2" })

      expect(described_class.count).to eq(1)
      expect(described_class.last.count).to eq(2)
    end

    it "allows custom increment amount" do
      described_class.increment(name: "auth.attempt", status: "success", increment_by: 5)

      expect(described_class.last.count).to eq(5)
    end

    it "defaults to success status when not specified" do
      described_class.increment(name: "session.created")

      metric = described_class.last
      expect(metric.status).to eq("success")
      expect(metric.count).to eq(1)
    end
  end

  describe ".total_count" do
    before do
      described_class.create!(
        name: "auth.attempt",
        status: "success",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 100
      )
      described_class.create!(
        name: "auth.attempt",
        status: "failure",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 10
      )
      described_class.create!(
        name: "auth.attempt",
        status: "success",
        dimensions: {},
        time_bucket: 1.hour.ago.beginning_of_hour,
        count: 50
      )
    end

    it "returns total count for a metric in time range" do
      range = Time.current.beginning_of_day..Time.current.end_of_day
      total = described_class.total_count(name: "auth.attempt", time_range: range)
      expect(total).to eq(160)
    end

    it "filters by status" do
      range = Time.current.beginning_of_day..Time.current.end_of_day
      total = described_class.total_count(
        name: "auth.attempt",
        time_range: range,
        status: "success"
      )
      expect(total).to eq(150)
    end

    it "returns 0 for non-existent metric" do
      range = Time.current.beginning_of_day..Time.current.end_of_day
      total = described_class.total_count(name: "nonexistent", time_range: range)
      expect(total).to eq(0)
    end
  end

  describe ".average_duration" do
    before do
      described_class.create!(
        name: "auth.latency",
        status: "success",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 10,
        total_duration: 500.0
      )
      described_class.create!(
        name: "auth.latency",
        status: "success",
        dimensions: {},
        time_bucket: 1.hour.ago.beginning_of_hour,
        count: 20,
        total_duration: 400.0
      )
    end

    it "calculates average duration from total_duration and count" do
      range = Time.current.beginning_of_day..Time.current.end_of_day
      avg = described_class.average_duration(name: "auth.latency", time_range: range)
      expect(avg).to eq(30.0) # (500 + 400) / (10 + 20)
    end

    it "returns nil when no data exists" do
      range = Time.current.beginning_of_day..Time.current.end_of_day
      avg = described_class.average_duration(name: "nonexistent", time_range: range)
      expect(avg).to be_nil
    end
  end

  describe ".success_rate" do
    it "calculates success rate as percentage" do
      described_class.create!(
        name: "auth.attempt",
        status: "success",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 90
      )
      described_class.create!(
        name: "auth.attempt",
        status: "failure",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 10
      )

      range = Time.current.beginning_of_day..Time.current.end_of_day
      rate = described_class.success_rate(name: "auth.attempt", time_range: range)
      expect(rate).to eq(90.0)
    end

    it "returns 100% for metrics with only success status" do
      described_class.create!(
        name: "session.created",
        status: "success",
        dimensions: {},
        time_bucket: Time.current.beginning_of_hour,
        count: 100
      )

      range = Time.current.beginning_of_day..Time.current.end_of_day
      rate = described_class.success_rate(name: "session.created", time_range: range)
      expect(rate).to eq(100.0)
    end

    it "returns nil when no data exists" do
      range = Time.current.beginning_of_day..Time.current.end_of_day
      rate = described_class.success_rate(name: "nonexistent", time_range: range)
      expect(rate).to be_nil
    end
  end

  describe "concurrent upserts" do
    it "handles concurrent increments correctly" do
      threads = 10.times.map do
        Thread.new do
          5.times do
            described_class.increment(name: "concurrent.test", status: "success")
          end
        end
      end

      threads.each(&:join)

      total = described_class.for_metric("concurrent.test").sum(:count)
      expect(total).to eq(50)
    end
  end
end
