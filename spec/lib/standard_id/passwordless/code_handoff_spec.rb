require "rails_helper"

# StandardId::Passwordless.issued_code / CodeHandoff: the raw one-time code
# reaches delivery out of band, so it is available under
# events.publish_records = false without ever being part of the payload that
# audit and logging subscribers serialise.
RSpec.describe StandardId::Passwordless::CodeHandoff do
  let(:email) { "handoff@example.com" }
  let(:realm) { "handoff_verification" }

  def issue(target = email, delivery: :custom)
    StandardId::Otp.issue(realm: realm, target: target, channel: :email, delivery: delivery)
  end

  # Runs +block+ inside a PASSWORDLESS_CODE_GENERATED subscriber for every
  # code issued while +issuing+ runs; returns the events seen.
  def on_generated(issuing, &block)
    events = []
    subscription = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_GENERATED) do |event|
      events << event
      block&.call(event)
    end
    issuing.call
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def stored_digest(code)
    StandardId::CodeChallenge.digest_code(code)
  end

  context "with events.publish_records = false" do
    before { StandardId.config.events.publish_records = false }

    it "publishes no record, but hands the subscriber the raw code" do
      codes = []
      events = on_generated(-> { issue }) { |event| codes << StandardId::Passwordless.issued_code(event) }

      expect(events.first.payload).not_to have_key(:code_challenge)
      expect(codes.size).to eq(1)
      expect(codes.first).to match(/\A\d{6}\z/)
      expect(StandardId::CodeChallenge.last.code_digest).to eq(stored_digest(codes.first))
    end

    it "keeps the code out of the payload however a subscriber serialises it" do
      code = nil
      events = on_generated(-> { issue }) { |event| code = StandardId::Passwordless.issued_code(event) }
      payload = events.first.payload

      expect(code).to be_present
      [payload.to_json, payload.inspect, payload.to_h.to_s, YAML.dump(payload.to_h)].each do |serialised|
        expect(serialised).not_to include(code)
      end
      expect(payload.values.map(&:to_s)).not_to include(code)
    end

    it "returns nil once the event has been published" do
      events = on_generated(-> { issue })

      expect(StandardId::Passwordless.issued_code(events.first)).to be_nil
      expect(ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY]).to be_nil
    end

    it "returns nil to another thread while the event is being published" do
      from_other_thread = :unset
      on_generated(-> { issue }) do |event|
        from_other_thread = Thread.new { StandardId::Passwordless.issued_code(event) }.value
      end

      expect(from_other_thread).to be_nil
    end

    it "returns nil for any other event published while it runs" do
      other = nil
      on_generated(-> { issue }) do |event|
        other = StandardId::Passwordless.issued_code(event.payload.merge(event_type: StandardId::Events::PASSWORDLESS_CODE_SENT))
      end

      expect(other).to be_nil
    end

    it "returns nil for an event about a different challenge" do
      mismatched = nil
      on_generated(-> { issue }) do |event|
        mismatched = StandardId::Passwordless.issued_code(event.payload.merge(code_challenge_id: SecureRandom.uuid))
      end

      expect(mismatched).to be_nil
    end

    it "still answers when record identifiers are off too" do
      StandardId.config.events.publish_record_identifiers = false
      code = nil
      events = on_generated(-> { issue }) { |event| code = StandardId::Passwordless.issued_code(event) }

      expect(events.first.payload).not_to have_key(:code_challenge_id)
      expect(StandardId::CodeChallenge.last.code_digest).to eq(stored_digest(code))
    end

    it "answers a code issued from inside a subscriber for its own event" do
      seen = {}
      issued_inner = false
      on_generated(-> { issue }) do |event|
        if event[:identifier] == email && !issued_inner
          issued_inner = true
          issue("inner@example.com")
        end
        (seen[event[:identifier]] ||= []) << StandardId::Passwordless.issued_code(event)
      end

      digests = StandardId::CodeChallenge.where(realm: realm).pluck(:target, :code_digest).to_h
      expect(digests.fetch(email)).to eq(stored_digest(seen.fetch(email).sole))
      expect(digests.fetch("inner@example.com")).to eq(stored_digest(seen.fetch("inner@example.com").sole))
    end

    it "clears the handoff when a subscriber raises" do
      subscription = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_GENERATED) { raise "boom" }

      expect { issue }.to raise_error(StandardError)
      expect(ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY]).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end

    it "lets the built-in mailer deliver the code and report it sent" do
      allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)
      statuses = []
      sent = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_SENT) { |e| statuses << e[:delivery_status] }

      expect { issue(delivery: :built_in) }.to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)
      expect(statuses).to eq(["sent"])
    ensure
      ActiveSupport::Notifications.unsubscribe(sent) if sent
    end

    it "lets StandardId::Testing::OtpHelpers capture the code" do
      helper = Object.new.extend(StandardId::Testing::OtpHelpers)

      code = helper.capture_otp_code(email) { issue }

      expect(StandardId::CodeChallenge.last.code_digest).to eq(stored_digest(code))
    end
  end

  context "with events.publish_records = true (the default)" do
    it "returns the published record's code" do
      pairs = []
      on_generated(-> { issue }) { |event| pairs << [StandardId::Passwordless.issued_code(event), event[:code_challenge].code] }

      expect(pairs.sole.first).to be_present
      expect(pairs.sole.first).to eq(pairs.sole.last)
    end

    it "returns nil for a challenge read back from the database" do
      issue
      reloaded = StandardId::CodeChallenge.last

      expect(StandardId::Passwordless.issued_code({ code_challenge: reloaded })).to be_nil
    end
  end
end
