require "rails_helper"

# GET /userinfo builds its claims from the host's account model, which need not
# define every attribute the gem reads: sidekick-web's Account has no `name`.
# OIDC makes every claim but `sub` optional, so a missing attribute omits its
# claim instead of raising NoMethodError (a 500 for every caller).
RSpec.describe "GET /api/userinfo", type: :request do
  let(:email) { "userinfo-#{SecureRandom.hex(4)}@example.com" }
  let!(:account) { create_account_with_password(email: email, password: "Sup3r-secret!", name: "Ada Lovelace") }

  def bearer
    token = StandardId::JwtService.encode({ sub: account.id, client_id: "test-client", scope: "read" })
    { "Authorization" => "Bearer #{token}" }
  end

  it "returns the account's claims" do
    get "/api/userinfo", headers: bearer

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "sub" => account.id.to_s,
      "name" => "Ada Lovelace",
      "email" => email,
      "email_verified" => true,
      "updated_at" => account.reload.updated_at.to_i
    )
  end

  it "reports email_verified false while the email identifier is unverified" do
    StandardId::EmailIdentifier.find_by!(value: email).update!(verified_at: nil)

    get "/api/userinfo", headers: bearer

    expect(response.parsed_body["email_verified"]).to be(false)
  end

  context "when the account model has no name attribute" do
    before do
      nameless = stub_const("NamelessAccount", Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        self.ignored_columns += %w[name]
      end)
      allow(StandardId).to receive(:account_class).and_return(nameless)
    end

    it "returns 200 without a name claim" do
      get "/api/userinfo", headers: bearer

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("name")
      expect(response.parsed_body).to include("sub" => account.id.to_s, "email" => email, "email_verified" => true)
    end
  end

  context "when the account model has neither name nor email" do
    before do
      bare = stub_const("BareAccount", Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        self.ignored_columns += %w[name email]
      end)
      allow(StandardId).to receive(:account_class).and_return(bare)
    end

    it "returns only the claims the model can supply" do
      get "/api/userinfo", headers: bearer

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to contain_exactly("sub", "updated_at")
    end
  end
end
