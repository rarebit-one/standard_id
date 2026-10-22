require "rails_helper"
require "standard_id/testing"

# End to end through the dummy app: the cookies sign_in_as writes must be the
# ones Web::SessionManager reads on a real request.
RSpec.describe "StandardId::Testing::RequestHelpers#sign_in_as", type: :request do
  RSpec::Matchers.define_negated_matcher :not_change, :change

  include StandardId::Testing::RequestHelpers

  let(:account) { Account.create!(email: "signed-in@example.com", name: "Signed In") }

  it "authenticates the next request with a real browser session" do
    browser_session = sign_in_as(account)

    get admin_root_path, headers: { "User-Agent" => "RSpec" }

    expect(response).to have_http_status(:ok)
    expect(browser_session).to be_persisted
    expect(browser_session.account).to eq(account)
  end

  it "stops authenticating once the session is revoked, as in production" do
    sign_in_as(account).revoke!

    get admin_root_path, headers: { "User-Agent" => "RSpec" }

    expect(response).to have_http_status(:redirect)
    expect(response.location).to include(standard_id_web.login_path)
  end

  it "stops authenticating once the session has expired" do
    sign_in_as(account).update!(expires_at: 1.minute.ago)

    get admin_root_path, headers: { "User-Agent" => "RSpec" }

    expect(response).to have_http_status(:redirect)
  end

  it "leaves the request unauthenticated without it" do
    get admin_root_path, headers: { "User-Agent" => "RSpec" }

    expect(response).to have_http_status(:redirect)
  end

  it "grants scopes through the Rails session" do
    sign_in_as(account, scope: [:platform, "lender"])

    get admin_root_path, headers: { "User-Agent" => "RSpec" }

    expect(response).to have_http_status(:ok)
    expect(session[:standard_id_scopes]).to eq(%w[platform lender])
  end

  it "refuses scopes on a session store it cannot write" do
    allow(Rails.application.config).to receive(:session_store).and_return(ActionDispatch::Session::CacheStore)

    expect { sign_in_as(account, scope: :platform) }
      .to raise_error(ArgumentError, /needs the cookie session store/)
      .and(not_change(StandardId::BrowserSession, :count))
  end

  it "refuses scopes when sessions are disabled" do
    allow(Rails.application.config).to receive(:session_store).and_return(nil)

    expect { sign_in_as(account, scope: :platform) }
      .to raise_error(ArgumentError, /needs the cookie session store/)
  end

  it "builds bearer headers for an account" do
    headers = bearer_headers_for(account, scope: "openid profile")

    decoded = StandardId::JwtService.decode(headers.fetch("Authorization").delete_prefix("Bearer "))
    expect(decoded["sub"]).to eq(account.id)
    expect(decoded["scope"]).to eq("openid profile")
  end
end
