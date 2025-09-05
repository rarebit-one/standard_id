require "rails_helper"

RSpec.describe "StandardId::Api::PasswordlessController", type: :request do
  let(:path) { "/api/passwordless/start" }

  before do
    # Default no-op senders unless specifically asserted
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)
    allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(nil)
  end

  describe "POST /api/passwordless/start" do
    it "starts email flow and returns ok" do
      sender = double("email_sender")
      expect(sender).to receive(:call).with("user@example.com", kind_of(String))
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

      http_post_json path, params: { connection: "email", email: "user@example.com" }

      expect(response).to have_http_status(:ok)
      body = json_body
      expect(body).to include("message" => "Code sent successfully")

      challenge = StandardId::PasswordlessChallenge.last
      expect(challenge).to be_present
      expect(challenge.connection_type).to eq("email")
      expect(challenge.username).to eq("user@example.com")
      expect(challenge).to be_active
    end

    it "starts sms flow and returns ok" do
      sender = double("sms_sender")
      expect(sender).to receive(:call).with("+14155550123", kind_of(String))
      allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(sender)

      http_post_json path, params: { connection: "sms", phone_number: "+14155550123" }

      expect(response).to have_http_status(:ok)
      body = json_body
      expect(body).to include("message" => "Code sent successfully")

      challenge = StandardId::PasswordlessChallenge.last
      expect(challenge).to be_present
      expect(challenge.connection_type).to eq("sms")
      expect(challenge.username).to eq("+14155550123")
      expect(challenge).to be_active
    end

    it "requires username/email/phone_number" do
      http_post_json path, params: { connection: "email" }

      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("username, email, or phone_number parameter is required")
    end

    it "rejects unsupported connection" do
      http_post_json path, params: { connection: "fax", username: "123" }

      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("Unsupported connection type")
    end

    it "validates email format" do
      http_post_json path, params: { connection: "email", email: "not-an-email" }

      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("Invalid email format")
    end

    it "validates phone format" do
      http_post_json path, params: { connection: "sms", phone_number: "555-1234" }

      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("Invalid phone number format")
    end
  end
end
