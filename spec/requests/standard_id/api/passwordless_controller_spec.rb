require "rails_helper"

RSpec.describe "StandardId::Api::PasswordlessController", type: :request do
  let(:path) { "/api/passwordless/start" }

  describe "POST /api/passwordless/start" do
    it "starts email flow and returns ok" do
      codes = capture_passwordless_codes

      http_post_json path, params: { connection: "email", email: "user@example.com" }

      expect(codes).to contain_exactly(["user@example.com", kind_of(String)])
      expect(response).to have_http_status(:ok)
      body = json_body
      expect(body).to include("message" => "Code sent successfully")

      challenge = StandardId::CodeChallenge.last
      expect(challenge).to be_present
      expect(challenge.channel).to eq("email")
      expect(challenge.target).to eq("user@example.com")
      expect(challenge).to be_active
    end

    it "starts sms flow and returns ok" do
      codes = capture_passwordless_codes

      http_post_json path, params: { connection: "sms", phone_number: "+14155550123" }

      expect(codes).to contain_exactly(["+14155550123", kind_of(String)])
      expect(response).to have_http_status(:ok)
      body = json_body
      expect(body).to include("message" => "Code sent successfully")

      challenge = StandardId::CodeChallenge.last
      expect(challenge).to be_present
      expect(challenge.channel).to eq("sms")
      expect(challenge.target).to eq("+14155550123")
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

    it "rejects an e-mail domain without a registered TLD before any delivery event" do
      events = capture_passwordless_start_events

      http_post_json path, params: { connection: "email", email: "jaryl@rarebit.ome" }

      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to eq("rarebit.ome isn't a valid e-mail domain. Check the address.")
      expect(events).to be_empty
      expect(StandardId::CodeChallenge.count).to eq(0)
    end

    it "accepts an uppercase address on a registered TLD" do
      codes = capture_passwordless_codes

      http_post_json path, params: { connection: "email", email: "User@Example.CO.UK" }

      expect(response).to have_http_status(:ok)
      expect(codes.size).to eq(1)
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
