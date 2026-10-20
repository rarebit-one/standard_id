require "rails_helper"

# config.social.before_mint on the API social callback: the one place a host
# can make the account ready for the mint (provision the audience-bound
# profile, run a region check) without subclassing the controller and copying
# #callback to reorder its steps.
RSpec.describe "config.social.before_mint on POST /api/oauth/callback/:provider", type: :request do
  let(:email) { "before-mint-#{SecureRandom.hex(4)}@example.com" }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
    allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
      { user_info: { "email" => email, "email_verified" => true, "sub" => "g-#{SecureRandom.hex(4)}" }, tokens: { "id_token" => "t" } }.with_indifferent_access
    )
  end

  def with_hook(callable)
    allow(StandardId.config.social).to receive(:before_mint).and_return(callable)
  end

  def json = JSON.parse(response.body)

  it "runs after the account exists and before the token is minted, with the callback's context" do
    order = []
    seen = nil
    sub = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_ISSUING) { |_| order << :issuing }
    with_hook(->(account:, provider:, social_info:, audience:, scopes:, params:) {
      order << :hook
      seen = [account.persisted?, provider, social_info["email"], audience, scopes, params]
    })

    post "/api/oauth/callback/google", params: { code: "c", audience: "api", scope: "profile", region: "sg" }

    expect(response).to have_http_status(:ok)
    expect(order).to eq(%i[hook issuing])
    expect(seen[0]).to be true
    expect(seen[1]).to eq("google")
    expect(seen[2]).to eq(email)
    # The requested audience and scopes arrive as their own keywords: the
    # forwarded params strip the reserved OAuth ones, so they are not in params.
    expect(seen[3]).to eq("api")
    expect(seen[4]).to eq("profile")
    expect(seen[5]).to eq({ "region" => "sg" })
  ensure
    StandardId::Events.unsubscribe(sub)
  end

  it "passes only the keywords the callable accepts" do
    with_hook(-> { :ok })

    post "/api/oauth/callback/google", params: { code: "c" }

    expect(response).to have_http_status(:ok)
  end

  it "refuses the sign-in through the callback's cleanup when it raises: nothing minted, a new account removed" do
    with_hook(->(account:) { raise StandardId::InvalidGrantError, "region blocked" })

    expect {
      post "/api/oauth/callback/google", params: { code: "c" }
    }.not_to change(Account, :count)

    expect(response).to have_http_status(:bad_request)
    expect(json["error"]).to eq("invalid_grant")
    expect(StandardId::RefreshToken.count).to eq(0)
  end

  it "is a no-op when unset" do
    with_hook(nil)

    post "/api/oauth/callback/google", params: { code: "c" }

    expect(response).to have_http_status(:ok)
    expect(json["access_token"]).to be_present
  end
end
