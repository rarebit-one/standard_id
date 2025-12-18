require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::AggregatedMetricsSubscriber do
  let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil) }

  before do
    clear_event_subscribers!
    allow(StandardId).to receive(:logger).and_return(logger)
    allow(StandardId.config.events).to receive(:enable_metrics).and_return(true)
    allow(StandardId.config.events).to receive(:metrics_bucket_size).and_return(:hour)
  end

  after do
    clear_event_subscribers!
  end

  describe "METRIC_MAPPINGS constant" do
    it "includes authentication success mapping" do
      mapping = described_class::METRIC_MAPPINGS["authentication.attempt.succeeded"]
      expect(mapping[:name]).to eq("auth.attempt")
      expect(mapping[:status]).to eq("success")
    end

    it "includes authentication failure mapping" do
      mapping = described_class::METRIC_MAPPINGS["authentication.attempt.failed"]
      expect(mapping[:name]).to eq("auth.attempt")
      expect(mapping[:status]).to eq("failure")
    end

    it "includes session events" do
      expect(described_class::METRIC_MAPPINGS).to have_key("session.created")
      expect(described_class::METRIC_MAPPINGS).to have_key("session.revoked")
      expect(described_class::METRIC_MAPPINGS).to have_key("session.expired")
    end

    it "includes OAuth events" do
      expect(described_class::METRIC_MAPPINGS).to have_key("oauth.token.issued")
      expect(described_class::METRIC_MAPPINGS).to have_key("oauth.authorization.granted")
      expect(described_class::METRIC_MAPPINGS).to have_key("oauth.authorization.denied")
    end
  end

  describe "#call" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.authentication.attempt.succeeded",
        payload: {
          event_type: "authentication.attempt.succeeded",
          event_id: SecureRandom.uuid,
          timestamp: Time.current.iso8601,
          auth_method: "password",
          ip_address: "192.168.1.1"
        },
        started_at: Time.current - 0.05,
        finished_at: Time.current
      )
    end

    it "creates a metric for authentication success" do
      expect { described_class.new.call(event) }
        .to change { StandardId::Metric.count }.by(1)
    end

    it "stores the correct metric name" do
      described_class.new.call(event)

      metric = StandardId::Metric.last
      expect(metric.name).to eq("auth.attempt")
    end

    it "stores success status" do
      described_class.new.call(event)

      metric = StandardId::Metric.last
      expect(metric.status).to eq("success")
    end

    it "stores auth_method in dimensions" do
      described_class.new.call(event)

      metric = StandardId::Metric.last
      expect(metric.dimensions["auth_method"]).to eq("password")
    end

    it "stores duration in total_duration for latency tracking" do
      described_class.new.call(event)

      metric = StandardId::Metric.last
      expect(metric.total_duration).to be > 0
    end

    it "increments count on subsequent calls" do
      subscriber = described_class.new

      subscriber.call(event)
      subscriber.call(event)

      metric = StandardId::Metric.last
      expect(metric.count).to eq(2)
    end

    context "when metrics are disabled" do
      before do
        allow(StandardId.config.events).to receive(:enable_metrics).and_return(false)
      end

      it "does not create a metric metric" do
        expect { described_class.new.call(event) }
          .not_to change { StandardId::Metric.count }
      end
    end

    context "with authentication failure event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.authentication.attempt.failed",
          payload: {
            event_type: "authentication.attempt.failed",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            auth_method: "password",
            error_code: "invalid_credentials"
          }
        )
      end

      it "stores failure status" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.status).to eq("failure")
      end

      it "stores error_code in dimensions" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.dimensions["error_code"]).to eq("invalid_credentials")
      end
    end

    context "with session created event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.session.created",
          payload: {
            event_type: "session.created",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            session_type: "browser"
          }
        )
      end

      it "stores session_type in dimensions" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.name).to eq("session.created")
        expect(metric.dimensions["session_type"]).to eq("browser")
      end
    end

    context "with OAuth event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.oauth.token.issued",
          payload: {
            event_type: "oauth.token.issued",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            grant_type: "authorization_code"
          }
        )
      end

      it "stores grant_type in dimensions" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.name).to eq("oauth.token.issued")
        expect(metric.dimensions["grant_type"]).to eq("authorization_code")
      end
    end

    context "with social auth event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.social.auth.completed",
          payload: {
            event_type: "social.auth.completed",
            event_id: SecureRandom.uuid,
            timestamp: Time.current.iso8601,
            provider: "google"
          }
        )
      end

      it "stores provider in dimensions" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.name).to eq("social.auth")
        expect(metric.dimensions["provider"]).to eq("google")
      end
    end

    context "with unmapped event" do
      let(:event) do
        StandardId::Events::Event.new(
          name: "standard_id.some.unmapped.event",
          payload: {
            event_type: "some.unmapped.event",
            event_id: SecureRandom.uuid
          }
        )
      end

      it "does not create a metric" do
        expect { described_class.new.call(event) }
          .not_to change { StandardId::Metric.count }
      end
    end
  end

  describe "time bucket calculation" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.authentication.attempt.succeeded",
        payload: {
          event_type: "authentication.attempt.succeeded",
          event_id: SecureRandom.uuid,
          timestamp: Time.current.iso8601
        }
      )
    end

    context "with five_minutes bucket (default)" do
      it "rounds time to 5-minute boundary" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.time_bucket.min % 5).to eq(0)
        expect(metric.time_bucket.sec).to eq(0)
      end
    end

    context "with one_minute bucket" do
      before do
        allow(StandardId.config.events).to receive(:metrics_bucket_size).and_return(:one_minute)
      end

      it "rounds time to beginning of minute" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.time_bucket.sec).to eq(0)
      end
    end

    context "with fifteen_minutes bucket" do
      before do
        allow(StandardId.config.events).to receive(:metrics_bucket_size).and_return(:fifteen_minutes)
      end

      it "rounds time to 15-minute boundary" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.time_bucket.min % 15).to eq(0)
        expect(metric.time_bucket.sec).to eq(0)
      end
    end

    context "with thirty_minutes bucket" do
      before do
        allow(StandardId.config.events).to receive(:metrics_bucket_size).and_return(:thirty_minutes)
      end

      it "rounds time to 30-minute boundary" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.time_bucket.min % 30).to eq(0)
        expect(metric.time_bucket.sec).to eq(0)
      end
    end

    context "with one_hour bucket" do
      before do
        allow(StandardId.config.events).to receive(:metrics_bucket_size).and_return(:one_hour)
      end

      it "rounds time to beginning of hour" do
        described_class.new.call(event)

        metric = StandardId::Metric.last
        expect(metric.time_bucket).to eq(Time.current.beginning_of_hour)
      end
    end
  end

  describe "#handle_error" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.authentication.attempt.succeeded",
        payload: { event_type: "authentication.attempt.succeeded" }
      )
    end

    it "logs the error with structured payload" do
      error = StandardError.new("Database connection failed")
      error.set_backtrace(["line1", "line2", "line3"])

      expect(logger).to receive(:error) do |payload|
        expect(payload[:subject]).to eq("standard_id.aggregated_metrics_subscriber.error")
        expect(payload[:event_type]).to eq("authentication.attempt.succeeded")
        expect(payload[:error]).to eq("Database connection failed")
      end

      expect { described_class.new.handle_error(error, event) }.not_to raise_error
    end
  end
end
