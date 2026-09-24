require "rails_helper"

RSpec.describe "StandardId config: removed and deprecated settings" do
  describe "StandardId.deprecator" do
    it "is registered with the host's deprecators" do
      expect(Rails.application.deprecators[:standard_id]).to be(StandardId.deprecator)
    end
  end

  # Deprecated in 0.42, removed in 0.43. Assigning raises with the hint rather
  # than the generic "Unknown field" (or, for a top-level base field, rather
  # than being silently stored and ignored).
  {
    %i[oauth client_id] => ["abc", /oauth\.client_id was removed in StandardId 0\.43: .*ClientApplication/],
    %i[oauth client_secret] => ["shh", /oauth\.client_secret was removed in StandardId 0\.43: .*ClientSecretCredential/],
    %i[passwordless enabled] => [true, /passwordless\.enabled was removed in StandardId 0\.43: .*web\.passwordless_login/],
    %i[rate_limits password_login_per_ip] => [30, /password_login_per_ip was removed in StandardId 0\.43: use rate_limits\.login_per_ip/],
    %i[rate_limits password_login_per_email] => [9, /password_login_per_email was removed in StandardId 0\.43: use rate_limits\.login_per_email/],
    %i[base passwordless_email_sender] => [->(*) { }, /config\.passwordless_email_sender was removed in StandardId 0\.43: .*PASSWORDLESS_CODE_GENERATED/],
    %i[base passwordless_sms_sender] => [->(*) { }, /config\.passwordless_sms_sender was removed in StandardId 0\.43: .*PASSWORDLESS_CODE_GENERATED/]
  }.each do |(scope, field), (value, message)|
    describe "#{scope}.#{field}" do
      it "raises ConfigurationError naming the replacement when assigned (even nil)" do
        options = StandardId.config[scope]

        expect { options[field] = value }.to raise_error(StandardId::ConfigurationError, message)
        expect { options[field] = nil }.to raise_error(StandardId::ConfigurationError, message)
        expect { options.public_send(:"#{field}=", value) }.to raise_error(StandardId::ConfigurationError, message)
      end

      it "is no longer a schema field" do
        expect(StandardId::ConfigSchema.instance.field?(scope, field)).to be(false)
      end
    end
  end

  it "rejects the unscoped top-level writer for a removed base field" do
    expect { StandardId.config.passwordless_email_sender = ->(*) { } }
      .to raise_error(StandardId::ConfigurationError, /passwordless_email_sender was removed/)
    expect(StandardId.config.key?(:passwordless_email_sender)).to be(false)
  end

  it "reads a removed top-level base field as nil (hosts asserting it is unset keep passing)" do
    expect(StandardId.config.passwordless_email_sender).to be_nil
  end

  it "raises the removal hint when a removed scoped field is read" do
    expect { StandardId.config.oauth.client_id }
      .to raise_error(StandardId::ConfigurationError, /oauth\.client_id was removed/)
  end

  describe "the schema's deprecated:/removed mechanism" do
    let(:schema) do
      StandardId::ConfigSchema.new.define do
        scope :demo do
          field :old_name, type: :integer, default: 1, deprecated: "use demo.new_name."
          field :new_name, type: :integer, default: 1
          removed :gone, "use demo.new_name."
        end
      end
    end
    let(:demo) { schema.apply(StandardId::ConfigSchema::Config.new).demo }

    it "warns (and stores) when a deprecated field is assigned non-nil, pointing at the assigning line" do
      callstack = nil
      expect(StandardId.deprecator).to receive(:warn).with(/demo\.old_name is deprecated: use demo\.new_name/, anything) { |_m, stack| callstack = stack }

      demo.old_name = 5

      expect(demo.old_name).to eq(5)
      expect(callstack.first.path).to eq(__FILE__)
    end

    it "does not warn for nil, reads, or non-deprecated fields" do
      expect(StandardId.deprecator).not_to receive(:warn)

      demo.old_name = nil
      demo.old_name
      demo.new_name = 3
    end

    it "raises for a removed field and keeps the generic error for unknown ones" do
      expect { demo.gone = 1 }.to raise_error(StandardId::ConfigurationError, /demo\.gone was removed in StandardId 0\.43: use demo\.new_name/)
      expect { demo.never_existed = 1 }.to raise_error(StandardId::ConfigurationError, /Unknown field 'never_existed'/)
    end
  end
end
