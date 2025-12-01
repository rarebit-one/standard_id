require "rails_helper"

RSpec.describe StandardId::BrowserSession, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { Account.create!(name: "Test User", email: "test@example.com") }

  describe "inheritance" do
    it "inherits from StandardId::Session" do
      expect(StandardId::BrowserSession.superclass).to eq(StandardId::Session)
    end
  end

  describe "validations" do
    it "validates presence of user_agent" do
      session = StandardId::BrowserSession.new(account: account, user_agent: "")
      expect(session).not_to be_valid
      expect(session.errors[:user_agent]).to include("can't be blank")
    end
  end

  describe "class methods" do
    describe ".expiry" do
      it "returns configured browser_session_lifetime from now" do
        travel_to Time.current do
          expected_expiry = StandardId.config.session.browser_session_lifetime.seconds.from_now
          expect(StandardId::BrowserSession.expiry).to eq(expected_expiry)
        end
      end

      it "defaults to 24 hours" do
        travel_to Time.current do
          expect(StandardId::BrowserSession.expiry).to eq(24.hours.from_now)
        end
      end
    end
  end

  describe "instance methods" do
    let(:browser_session) do
      StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        expires_at: 2.weeks.from_now
      )
    end

    describe "#browser_info" do
      it "detects Chrome browser" do
        browser_session.update!(user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36")
        info = browser_session.browser_info
        expect(info[:browser]).to eq('Chrome')
        expect(info[:type]).to eq('browser')
      end

      it "detects Firefox browser" do
        browser_session.update!(user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:89.0) Gecko/20100101 Firefox/89.0")
        info = browser_session.browser_info
        expect(info[:browser]).to eq('Firefox')
        expect(info[:type]).to eq('browser')
      end

      it "detects Safari browser" do
        browser_session.update!(user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Safari/605.1.15")
        info = browser_session.browser_info
        expect(info[:browser]).to eq('Safari')
        expect(info[:type]).to eq('browser')
      end

      it "detects Edge browser" do
        browser_session.update!(user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 Edge/91.0.864.59")
        info = browser_session.browser_info
        expect(info[:browser]).to eq('Edge')
        expect(info[:type]).to eq('browser')
      end

      it "returns unknown for unrecognized user agents" do
        browser_session.update!(user_agent: "CustomBrowser/1.0")
        info = browser_session.browser_info
        expect(info[:browser]).to eq('Unknown')
        expect(info[:type]).to eq('browser')
      end

      it "returns empty hash for blank user_agent" do
        # Create a new session with blank user_agent to test the method directly
        session_with_blank_agent = StandardId::BrowserSession.new(
          account: account,
          user_agent: "Test Agent",
          expires_at: 2.weeks.from_now
        )
        session_with_blank_agent.save!
        session_with_blank_agent.user_agent = ""
        expect(session_with_blank_agent.browser_info).to eq({})
      end
    end

    describe "#display_name" do
      it "returns browser-specific display name" do
        browser_session.update!(user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36")
        expect(browser_session.display_name).to eq("Chrome Browser Session")
      end

      it "returns unknown browser display name for unrecognized agents" do
        browser_session.update!(user_agent: "CustomBrowser/1.0")
        expect(browser_session.display_name).to eq("Unknown Browser Session")
      end
    end
  end
end
