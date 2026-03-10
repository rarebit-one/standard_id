require "rails_helper"

RSpec.describe StandardId::BearerTokenExtraction do
  let(:controller_class) do
    Class.new(ActionController::API) do
      include StandardId::BearerTokenExtraction

      # Expose private method for testing
      public :extract_bearer_token
    end
  end

  let(:controller) { controller_class.new }

  before do
    allow(controller).to receive(:request).and_return(request)
  end

  describe "#extract_bearer_token" do
    context "when Authorization header contains a Bearer token" do
      let(:request) do
        instance_double(ActionDispatch::Request, headers: { "Authorization" => "Bearer abc123" })
      end

      it "returns the token" do
        expect(controller.extract_bearer_token).to eq("abc123")
      end
    end

    context "when Authorization header is missing" do
      let(:request) do
        instance_double(ActionDispatch::Request, headers: {})
      end

      it "returns nil" do
        expect(controller.extract_bearer_token).to be_nil
      end
    end

    context "when Authorization header uses a different scheme" do
      let(:request) do
        instance_double(ActionDispatch::Request, headers: { "Authorization" => "Basic dXNlcjpwYXNz" })
      end

      it "returns nil" do
        expect(controller.extract_bearer_token).to be_nil
      end
    end

    context "when token is a dot-separated JWT" do
      let(:request) do
        instance_double(ActionDispatch::Request, headers: { "Authorization" => "Bearer eyJ.abc.xyz" })
      end

      it "returns the full token" do
        expect(controller.extract_bearer_token).to eq("eyJ.abc.xyz")
      end
    end

    context "when Authorization header is 'Bearer ' with no token value" do
      let(:request) do
        instance_double(ActionDispatch::Request, headers: { "Authorization" => "Bearer " })
      end

      it "returns nil instead of an empty string" do
        expect(controller.extract_bearer_token).to be_nil
      end
    end
  end
end
