require "rails_helper"

RSpec.describe StandardId::ServiceSession, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { Account.create!(name: "Test Service", email: "service@example.com") }

  describe "inheritance" do
    it "inherits from StandardId::Session" do
      expect(StandardId::ServiceSession.superclass).to eq(StandardId::Session)
    end
  end

  describe "validations" do
    it "validates presence of service_name" do
      session = StandardId::ServiceSession.new(account: account, service_name: "", service_version: "1.0.0")
      expect(session).not_to be_valid
      expect(session.errors[:service_name]).to include("can't be blank")
    end

    it "validates presence of service_version" do
      session = StandardId::ServiceSession.new(account: account, service_name: "api-gateway", service_version: "")
      expect(session).not_to be_valid
      expect(session.errors[:service_version]).to include("can't be blank")
    end

    it "validates presence of owner" do
      session = StandardId::ServiceSession.new(account: account, service_name: "api-gateway", service_version: "1.0.0")
      expect(session).not_to be_valid
      expect(session.errors[:owner]).to include("can't be blank")
    end
  end

  describe "instance methods" do
    let(:service_session) do
      StandardId::ServiceSession.create!(
        account: account,
        service_name: "payment-processor",
        service_version: "2.1.3",
        owner: account,
        expires_at: 90.days.from_now
      )
    end

    describe "#display_name" do
      it "returns service-specific display name" do
        expect(service_session.display_name).to eq("payment-processor Service Session (v2.1.3)")
      end
    end

    describe "#service_info" do
      it "returns service information hash" do
        info = service_session.service_info
        expect(info[:name]).to eq('payment-processor')
        expect(info[:version]).to eq('2.1.3')
        expect(info[:type]).to eq('service')
      end
    end

    describe "#refresh!" do
      it "does not update any timestamps (no-op for service sessions)" do
        original_updated_at = service_session.updated_at
        travel_to 1.hour.from_now do
          service_session.refresh!
          expect(service_session.updated_at).to eq(original_updated_at)
        end
      end
    end

    describe "#stale?" do
      it "always returns false for service sessions" do
        expect(service_session.stale?).to be false
      end

      it "returns false even for old service sessions" do
        travel_to 30.days.from_now do
          expect(service_session.stale?).to be false
        end
      end
    end
  end

  describe "class methods" do
    describe ".expiry" do
      it "returns configured service_session_lifetime from now" do
        travel_to Time.current do
          expected_expiry = StandardId.config.session.service_session_lifetime.seconds.from_now
          expect(StandardId::ServiceSession.expiry).to eq(expected_expiry)
        end
      end

      it "defaults to 90 days" do
        travel_to Time.current do
          expect(StandardId::ServiceSession.expiry).to eq(90.days.from_now)
        end
      end
    end
  end

  describe "session lifecycle" do
    let(:session) do
      StandardId::ServiceSession.create!(
        account: account,
        service_name: "notification-service",
        service_version: "1.5.0",
        owner: account,
        expires_at: 90.days.from_now
      )
    end

    it "is active when created" do
      expect(session.active?).to be true
    end

    it "becomes inactive when revoked" do
      session.revoke!
      expect(session.active?).to be false
      expect(session.revoked?).to be true
    end

    it "becomes inactive when expired" do
      session.update!(expires_at: 1.day.ago)
      expect(session.active?).to be false
      expect(session.expired?).to be true
    end
  end

  describe "token generation" do
    it "generates token and digest on create" do
      session = described_class.create!(account: account, service_name: "svc", service_version: "1.0.0", owner: account)
      expect(session.lookup_hash).to be_present
      expect(session.token_digest).to be_present
    end

    it "can be found by token" do
      session = described_class.create!(account: account, service_name: "data-processor", service_version: "1.2.0", owner: account)
      token = session.instance_variable_get(:@token)
      found_session = described_class.by_token(token).first
      expect(found_session).to eq(session)
    end
  end

  describe "scopes" do
    let(:service_session) do
      StandardId::ServiceSession.create!(
        account: account,
        service_name: "test-service",
        service_version: "1.0.0",
        owner: account,
        expires_at: 30.days.from_now
      )
    end

    let!(:expired_session) do
      session = StandardId::ServiceSession.create!(
        account: account,
        service_name: "expired-service",
        service_version: "1.0.0",
        owner: account,
        expires_at: 1.day.ago
      )
    end

    let!(:revoked_session) do
      session = StandardId::ServiceSession.create!(
        account: account,
        service_name: "test-service",
        service_version: "1.0.0",
        owner: account,
        expires_at: 30.days.from_now
      )
      session.revoke!
      session
    end

    let!(:active_session) do
      StandardId::ServiceSession.create!(
        account: account,
        service_name: "active-service",
        service_version: "1.0.0",
        owner: account,
        expires_at: 30.days.from_now
      )
    end

    it "includes active sessions in active scope" do
      expect(StandardId::ServiceSession.active).to include(active_session)
      expect(StandardId::ServiceSession.active).not_to include(expired_session)
      expect(StandardId::ServiceSession.active).not_to include(revoked_session)
    end

    it "includes expired sessions in expired scope" do
      expect(StandardId::ServiceSession.expired).to include(expired_session)
      expect(StandardId::ServiceSession.expired).not_to include(active_session)
    end

    it "includes revoked sessions in revoked scope" do
      expect(StandardId::ServiceSession.revoked).to include(revoked_session)
      expect(StandardId::ServiceSession.revoked).not_to include(active_session)
      expect(StandardId::ServiceSession.revoked).not_to include(expired_session)
    end
  end
end
