require "rails_helper"

RSpec.describe "StandardId config deprecations" do
  describe "StandardId.deprecator" do
    it "is registered with the host's deprecators" do
      expect(Rails.application.deprecators[:standard_id]).to be(StandardId.deprecator)
    end

    it "is the deprecator ScopeConfig warns through" do
      expect(StandardId::ScopeConfig::DEPRECATOR).to be(StandardId.deprecator)
    end
  end

  {
    %i[oauth client_id] => ["abc", /oauth\.client_id is deprecated: .*ClientApplication/],
    %i[oauth client_secret] => ["shh", /oauth\.client_secret is deprecated: .*ClientSecretCredential/],
    %i[passwordless enabled] => [true, /passwordless\.enabled is deprecated: .*web\.passwordless_login/],
    %i[rate_limits password_login_per_ip] => [30, /password_login_per_ip is deprecated: use rate_limits\.login_per_ip/],
    %i[rate_limits password_login_per_email] => [9, /password_login_per_email is deprecated: use rate_limits\.login_per_email/],
    %i[base passwordless_email_sender] => [->(*) { }, /config\.passwordless_email_sender is deprecated: .*PASSWORDLESS_CODE_GENERATED/],
    %i[base passwordless_sms_sender] => [->(*) { }, /config\.passwordless_sms_sender is deprecated: .*PASSWORDLESS_CODE_GENERATED/]
  }.each do |(scope, field), (value, message)|
    describe "#{scope}.#{field}" do
      let(:options) { StandardId.config[scope] }

      around do |example|
        original = options[field]
        example.run
      ensure
        StandardId.deprecator.silence { options[field] = original }
      end

      it "warns when assigned" do
        expect(StandardId.deprecator).to receive(:warn).with(message, anything)

        options[field] = value
      end

      it "still stores the value (warning only, no removal)" do
        StandardId.deprecator.silence { options[field] = value }

        expect(options[field]).to eq(value)
      end

      it "does not warn when assigned nil or merely read" do
        expect(StandardId.deprecator).not_to receive(:warn)

        options[field] = nil
        options[field]
      end
    end
  end

  it "routes the unscoped top-level writer through the same warning" do
    original = StandardId.config.passwordless_email_sender
    expect(StandardId.deprecator).to receive(:warn).with(/passwordless_email_sender is deprecated/, anything)

    StandardId.config.passwordless_email_sender = ->(*) { }
  ensure
    StandardId.deprecator.silence { StandardId.config.passwordless_email_sender = original }
  end

  it "attributes the warning to the assigning code, not the config internals" do
    callstack = nil
    allow(StandardId.deprecator).to receive(:warn) { |_message, stack| callstack = stack }

    StandardId.config.oauth.client_id = "abc"

    expect(callstack.first.path).to eq(__FILE__)
  ensure
    StandardId.deprecator.silence { StandardId.config.oauth.client_id = nil }
  end

  it "does not warn for non-deprecated fields" do
    expect(StandardId.deprecator).not_to receive(:warn)

    original = StandardId.config.rate_limits.login_per_ip
    StandardId.config.rate_limits.login_per_ip = 25
  ensure
    StandardId.config.rate_limits.login_per_ip = original
  end
end
