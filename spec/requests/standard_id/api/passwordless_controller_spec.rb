require "rails_helper"

RSpec.describe "StandardId::Api::PasswordlessController", type: :request do
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
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

      post path, params: { connection: "email", email: "user@example.com" }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
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

      post path, params: { connection: "sms", phone_number: "+14155550123" }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to include("message" => "Code sent successfully")

      challenge = StandardId::PasswordlessChallenge.last
      expect(challenge).to be_present
      expect(challenge.connection_type).to eq("sms")
      expect(challenge.username).to eq("+14155550123")
      expect(challenge).to be_active
    end

    it "requires username/email/phone_number" do
      post path, params: { connection: "email" }.to_json, headers: headers

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("username, email, or phone_number parameter is required")
    end

    it "rejects unsupported connection" do
      post path, params: { connection: "fax", username: "123" }.to_json, headers: headers

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("Unsupported connection type")
    end

    it "validates email format" do
      post path, params: { connection: "email", email: "not-an-email" }.to_json, headers: headers

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("Invalid email format")
    end

    it "validates phone format" do
      post path, params: { connection: "sms", phone_number: "555-1234" }.to_json, headers: headers

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to include("Invalid phone number format")
    end
  end
end
