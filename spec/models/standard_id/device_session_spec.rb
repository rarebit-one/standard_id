require "rails_helper"

RSpec.describe StandardId::DeviceSession, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { Account.create!(name: "Test User", email: "test@example.com") }

  describe "inheritance" do
    it "inherits from StandardId::Session" do
      expect(StandardId::DeviceSession.superclass).to eq(StandardId::Session)
    end
  end

  describe "validations" do
    it "validates presence of device_id" do
      session = StandardId::DeviceSession.new(account: account, device_id: "", device_agent: "Test Agent")
      expect(session).not_to be_valid
      expect(session.errors[:device_id]).to include("can't be blank")
    end

    it "validates presence of device_agent" do
      session = StandardId::DeviceSession.new(account: account, device_id: "test-device", device_agent: "")
      expect(session).not_to be_valid
      expect(session.errors[:device_agent]).to include("can't be blank")
    end
  end

  describe "class methods" do
    describe ".expiry" do
      it "returns configured device_session_lifetime from now" do
        travel_to Time.current do
          expected_expiry = StandardId.config.session.device_session_lifetime.seconds.from_now
          expect(StandardId::DeviceSession.expiry).to eq(expected_expiry)
        end
      end

      it "defaults to 30 days" do
        travel_to Time.current do
          expect(StandardId::DeviceSession.expiry).to eq(30.days.from_now)
        end
      end
    end
  end

  describe "instance methods" do
    let(:device_session) do
      StandardId::DeviceSession.create!(
        account: account,
        device_id: "test-device-123",
        device_agent: "MyApp/1.0 (iPhone; iOS 14.6; Scale/3.00)",
        expires_at: 2.weeks.from_now
      )
    end

    describe "#device_info" do
      it "detects iOS devices" do
        device_session.update!(device_agent: "MyApp/1.0 (iPhone; iOS 14.6; Scale/3.00)")
        info = device_session.device_info
        expect(info[:platform]).to eq('iOS')
        expect(info[:type]).to eq('mobile')
      end

      it "detects Android devices" do
        device_session.update!(device_agent: "MyApp/1.0 (Android 11; SM-G991B)")
        info = device_session.device_info
        expect(info[:platform]).to eq('Android')
        expect(info[:type]).to eq('mobile')
      end

      it "detects Windows devices" do
        device_session.update!(device_agent: "MyApp/1.0 (Windows NT 10.0; Win64; x64)")
        info = device_session.device_info
        expect(info[:platform]).to eq('Windows')
        expect(info[:type]).to eq('desktop')
      end

      it "detects macOS devices" do
        device_session.update!(device_agent: "MyApp/1.0 (Macintosh; Intel Mac OS X 10_15_7)")
        info = device_session.device_info
        expect(info[:platform]).to eq('macOS')
        expect(info[:type]).to eq('desktop')
      end

      it "detects Linux devices" do
        device_session.update!(device_agent: "MyApp/1.0 (X11; Linux x86_64)")
        info = device_session.device_info
        expect(info[:platform]).to eq('Linux')
        expect(info[:type]).to eq('desktop')
      end

      it "returns unknown for unrecognized device agents" do
        device_session.update!(device_agent: "CustomDevice/1.0")
        info = device_session.device_info
        expect(info[:platform]).to eq('Unknown')
        expect(info[:type]).to eq('unknown')
      end

      it "returns empty hash for blank device_agent" do
        # Create a new session to test the method directly without validation
        session_with_blank_agent = StandardId::DeviceSession.new(
          account: account,
          device_id: "test-device",
          device_agent: "Test Agent",
          expires_at: 2.weeks.from_now
        )
        session_with_blank_agent.save!
        session_with_blank_agent.device_agent = ""
        expect(session_with_blank_agent.device_info).to eq({})
      end
    end

    describe "#display_name" do
      it "returns platform-specific display name" do
        device_session.update!(device_agent: "MyApp/1.0 (iPhone; iOS 14.6; Scale/3.00)")
        expect(device_session.display_name).to eq("iOS Device Session")
      end

      it "returns unknown device display name for unrecognized agents" do
        device_session.update!(device_agent: "CustomDevice/1.0")
        expect(device_session.display_name).to eq("Unknown Device Session")
      end
    end

    describe "#refresh!" do
      it "updates last_refreshed_at to current time" do
        travel_to Time.current do
          device_session.refresh!
          expect(device_session.last_refreshed_at).to eq(Time.current)
        end
      end
    end

    describe "#stale?" do
      it "returns true when last_refreshed_at is nil" do
        device_session.update_column(:last_refreshed_at, nil)
        expect(device_session.stale?).to be true
      end

      it "returns true when last_refreshed_at is more than 1 hour ago" do
        device_session.update_column(:last_refreshed_at, 2.hours.ago)
        expect(device_session.stale?).to be true
      end

      it "returns false when last_refreshed_at is within 1 hour" do
        device_session.update_column(:last_refreshed_at, 30.minutes.ago)
        expect(device_session.stale?).to be false
      end
    end
  end
end
