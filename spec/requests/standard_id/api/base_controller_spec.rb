require "rails_helper"

RSpec.describe "StandardId::Api::BaseController", type: :request do
  # Use the test_api endpoint which inherits from StandardId::Api::BaseController
  let(:path) { "/test_api" }

  describe "JSON content-type validation" do
    it "accepts application/json content type" do
      http_get path, headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:ok)
    end

    it "accepts vendor-specific JSON content types" do
      http_get path, headers: { "CONTENT_TYPE" => "application/vnd.api+json" }
      expect(response).to have_http_status(:ok)
    end

    it "accepts application/hal+json content type" do
      http_get path, headers: { "CONTENT_TYPE" => "application/hal+json" }
      expect(response).to have_http_status(:ok)
    end

    it "rejects non-JSON content types" do
      http_get path, headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to eq("Content-Type must be application/json or application/*+json")
    end

    it "rejects text/plain content type" do
      http_get path, headers: { "CONTENT_TYPE" => "text/plain" }
      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to eq("Content-Type must be application/json or application/*+json")
    end

    it "rejects application/xml content type" do
      http_get path, headers: { "CONTENT_TYPE" => "application/xml" }
      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to eq("Content-Type must be application/json or application/*+json")
    end

    it "handles missing content type gracefully" do
      http_get path
      expect(response).to have_http_status(:bad_request)
      body = json_body
      expect(body["error"]).to eq("invalid_request")
      expect(body["error_description"]).to eq("Content-Type must be application/json or application/*+json")
    end
  end

  describe "no-store headers" do
    it "sets Cache-Control and Pragma headers on successful responses" do
      http_get path, headers: { "CONTENT_TYPE" => "application/json" }

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Pragma"]).to eq("no-cache")
    end

    it "sets Cache-Control header on error responses" do
      http_get path, headers: { "CONTENT_TYPE" => "text/plain" }

      expect(response.headers["Cache-Control"]).to eq("no-cache")
    end
  end
end
