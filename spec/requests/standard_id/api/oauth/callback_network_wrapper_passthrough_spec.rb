require "rails_helper"

# A provider plugin runs each sign-in request (code exchange, JWKS fetch,
# tokeninfo, userinfo) inside Providers::Base#rescue_to_oauth_error, which
# turns errors into OAuthErrors. An error the host's network_wrapper passes
# through on purpose (here one listed in network_wrapper_passthrough_errors,
# like StandardCircuit::UnknownCircuit for an unregistered circuit) must not
# be turned into a handled 400 that names the circuit: it propagates, so it
# reaches the error tracker.
RSpec.describe "POST /api/oauth/callback/:provider when the network_wrapper passes an error through", type: :request do
  let(:unknown_circuit) { Class.new(StandardError) }
  let(:events) { [] }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
    allow(Resolv).to receive(:getaddresses).and_return(["93.184.216.34"])
    # A plugin's JWKS fetch, exactly as standard_id-google does it.
    allow(StandardId::Providers::Google).to receive(:get_user_info) do
      StandardId::Providers::Google.send(:rescue_to_oauth_error, "Failed to fetch Google JWKS") do
        StandardId::HttpClient.post_form("https://oauth2.example.com/token", { code: "c" }, provider: :google)
      end
      raise "the wrapper raises, so this is never reached"
    end
    @subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) { |event| events << event }
  end

  after { StandardId::Events.unsubscribe(@subscription) }

  def wrapper_raising(error_class)
    StandardId.config.network_wrapper = ->(provider:, &_block) { raise error_class, "no circuit registered for :oauth_#{provider}" }
  end

  it "propagates a listed error unchanged, not as a 400 or 503" do
    StandardId.config.network_wrapper_passthrough_errors = [unknown_circuit]
    wrapper_raising(unknown_circuit)

    expect { post "/api/oauth/callback/google", params: { code: "c" } }
      .to raise_error(unknown_circuit, "no circuit registered for :oauth_google") { |error|
        expect(error).not_to be_a(StandardId::OAuthError)
      }
    expect(events).to be_empty
    expect(WebMock).not_to have_requested(:post, "https://oauth2.example.com/token")
  end

  it "still answers 503 for an unlisted wrapper error (an outage)" do
    wrapper_raising(unknown_circuit)

    post "/api/oauth/callback/google", params: { code: "c" }

    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)).to eq(
      "error" => "temporarily_unavailable", "error_description" => "Google is temporarily unavailable"
    )
    expect(events.map { |event| event[:error_class] }).to eq(["StandardId::ProviderUnavailableError"])
  end

  it "still maps the request's own transport error inside the wrapper to an OAuthError" do
    StandardId.config.network_wrapper_passthrough_errors = [unknown_circuit]
    StandardId.config.network_wrapper = ->(provider:, &block) { block.call }
    stub_request(:post, "https://oauth2.example.com/token").to_raise(SocketError.new("getaddrinfo failed"))

    post "/api/oauth/callback/google", params: { code: "c" }

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)).to include("error" => "invalid_request",
                                                 "error_description" => "Failed to fetch Google JWKS: getaddrinfo failed")
    expect(events.map { |event| event[:error_class] }).to eq(["StandardId::OAuthError"])
  end
end
