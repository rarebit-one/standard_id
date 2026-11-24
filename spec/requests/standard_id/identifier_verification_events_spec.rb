require "rails_helper"

# identifier.verification.started / failed around proving an address: the web
# /verify_email and /verify_phone flows and c.email_password's sign-up code.
RSpec.describe "Identifier verification events", type: :request do
  let(:names) { [StandardId::Events::IDENTIFIER_VERIFICATION_STARTED, StandardId::Events::IDENTIFIER_VERIFICATION_FAILED] }
  let(:events) { [] }

  around do |example|
    subs = StandardId::Events.subscribe(*names) { |e| events << [e.short_name, e.payload] }
    example.run
  ensure
    StandardId::Events.unsubscribe(subs)
  end

  def fired = events.map(&:first)

  def payload_for(name) = events.find { |n, _| n == name }&.last

  def wrong_code_for(code) = code == "000000" ? "111111" : "000000"

  shared_examples "an address verification flow" do
    it "publishes started when the code is issued, never the code" do
      codes = capture_passwordless_codes
      start!

      expect(fired).to eq([StandardId::Events::IDENTIFIER_VERIFICATION_STARTED])
      expect(payload_for(StandardId::Events::IDENTIFIER_VERIFICATION_STARTED))
        .to include(identifier: target, channel: channel, realm: "verification")
      expect(payload_for(StandardId::Events::IDENTIFIER_VERIFICATION_STARTED).values.map(&:to_s)).not_to include(codes.last.last)
    end

    it "does not publish started when no code is issued" do
      start!(target: "")

      expect(events).to be_empty
    end

    it "publishes failed for a wrong code against a live code" do
      codes = capture_passwordless_codes
      start!
      events.clear

      confirm!(wrong_code_for(codes.last.last))

      expect(fired).to eq([StandardId::Events::IDENTIFIER_VERIFICATION_FAILED])
      expect(payload_for(StandardId::Events::IDENTIFIER_VERIFICATION_FAILED))
        .to include(identifier: target, channel: channel, realm: "verification", error_code: "invalid_code", attempts: 1)
    end

    it "publishes nothing for the right code" do
      codes = capture_passwordless_codes
      start!
      events.clear

      confirm!(codes.last.last)

      expect(events).to be_empty
    end

    it "publishes nothing for a target that was never sent a code" do
      confirm!("123456")

      expect(events).to be_empty
    end
  end

  describe "/verify_email" do
    let(:target) { "verify-#{SecureRandom.hex(4)}@example.com" }
    let(:channel) { "email" }

    def start!(target: self.target) = http_post("/verify_email/start", params: { email: target })
    def confirm!(code) = http_patch("/verify_email/confirm", params: { email: target, code: code })

    it_behaves_like "an address verification flow"
  end

  describe "/verify_phone" do
    let(:target) { "+1415555#{rand(1000..9999)}" }
    let(:channel) { "sms" }

    def start!(target: self.target) = http_post("/verify_phone/start", params: { phone_number: target })
    def confirm!(code) = http_patch("/verify_phone/confirm", params: { phone_number: target, code: code })

    it_behaves_like "an address verification flow"
  end

  describe "c.email_password sign-up code" do
    let(:email) { "signup-#{SecureRandom.hex(4)}@example.com" }
    let(:password) { "Sup3r-secret!" }
    let(:realm) { StandardId.config.email_password.verification_realm }

    before { StandardId.config.email_password.enabled = true }

    def register = http_post_json("/api/auth/register", params: { name: "Nova", email: email, password: password })

    def verify(code, pw: password)
      http_post_json("/api/auth/verify-email", params: { email: email, code: code, password: pw })
    end

    it "publishes started when sign-up sends the code" do
      register

      expect(fired).to eq([StandardId::Events::IDENTIFIER_VERIFICATION_STARTED])
      expect(payload_for(StandardId::Events::IDENTIFIER_VERIFICATION_STARTED)).to include(identifier: email, channel: "email", realm: realm)
    end

    it "publishes failed for a wrong code sent with the right password" do
      register
      events.clear

      verify(wrong_code_for(issued_otp_code(email)))

      expect(fired).to eq([StandardId::Events::IDENTIFIER_VERIFICATION_FAILED])
      expect(payload_for(StandardId::Events::IDENTIFIER_VERIFICATION_FAILED)).to include(identifier: email, realm: realm, attempts: 1)
    end

    it "publishes nothing for a wrong password, or for the right code" do
      register
      code = issued_otp_code(email)
      events.clear

      verify(wrong_code_for(code), pw: "Wr0ng-password!")
      verify(code)

      expect(response).to have_http_status(:ok)
      expect(events).to be_empty
    end
  end

  it "keeps both out of Events.auditable (passwordless.* and authentication.otp.* already record the codes)" do
    names.each do |short|
      name = StandardId::Events.namespaced_event_name(short)
      expect(StandardId::Events.auditable.any? { |p| p.is_a?(Regexp) ? p.match?(name) : p == name }).to be(false)
    end
  end
end
