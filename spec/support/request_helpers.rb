# frozen_string_literal: true

module RequestSpecHelpers
  # Default headers added to all helper HTTP methods to satisfy
  # BrowserSession validations (requires a User-Agent).
  def default_headers
    base = { "User-Agent" => "RSpec" }
    extra = @request_extra_headers || {}
    base.merge(extra)
  end

  # Convenience HTTP wrappers that always include default headers
  def http_get(path, params: {}, headers: {})
    get path, params: params, headers: default_headers.merge(headers)
  end

  def http_post(path, params: {}, headers: {})
    post path, params: params, headers: default_headers.merge(headers)
  end

  # JSON helpers
  def http_post_json(path, params: {}, headers: {})
    post path, params: params.to_json, headers: default_headers.merge({ "CONTENT_TYPE" => "application/json" }).merge(headers)
  end

  def http_patch(path, params: {}, headers: {})
    patch path, params: params, headers: default_headers.merge(headers)
  end

  def http_delete(path, params: {}, headers: {})
    delete path, params: params, headers: default_headers.merge(headers)
  end

  # Create an account with an email identifier and password credential
  def create_account_with_password(email:, password:, name: "Test User")
    account = Account.create!(name: name, email: email)
    identifier = StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
    password_credential = StandardId::PasswordCredential.create!(login: email, password: password)
    StandardId::Credential.create!(credentialable: password_credential, identifier: identifier)
    account
  end

  # Establish a browser session for the given account using the util endpoint
  def sign_in_as(account)
    browser_session = StandardId::BrowserSession.create!(
      account: account,
      ip_address: "127.0.0.1",
      user_agent: default_headers["User-Agent"],
      expires_at: 1.day.from_now
    )
    post util_session_path, params: { session_token: browser_session.token }
    browser_session
  end

  # Execute requests as an authenticated user
  # Usage:
  #   as_user(account) do
  #     http_get "/protected"
  #   end
  def as_user(account)
    sign_in_as(account)
    yield
  end

  # Authorization header helper for API requests
  def auth_headers(jwt)
    { "Authorization" => "Bearer #{jwt}" }
  end

  # Temporarily scope extra headers (e.g., Authorization) for a block
  def with_headers(headers)
    previous = @request_extra_headers
    @request_extra_headers = (previous || {}).merge(headers)
    yield
  ensure
    @request_extra_headers = previous
  end

  # Build a simple Bearer JWT for service/API requests
  def bearer_jwt(account: nil, sub: nil, client_id: "svc-test", scope: "service:read", grant_type: "access_token", extra: {})
    sub ||= account&.id
    claims = { sub: sub, client_id: client_id, scope: scope, grant_type: grant_type }.merge(extra)
    StandardId::JwtService.encode(claims)
  end

  # Execute requests as a service (JWT authenticated) within the given block
  # Usage:
  #   as_service(jwt: bearer_jwt(account: acct)) do
  #     http_get "/api/ping"
  #   end
  # Or let it build the token for you:
  #   as_service(account: acct, scope: "accounts:read") { http_get "/api/ping" }
  def as_service(jwt: nil, account: nil, sub: nil, client_id: "svc-test", scope: "service:read", grant_type: "access_token", extra: {})
    token = jwt || bearer_jwt(account: account, sub: sub, client_id: client_id, scope: scope, grant_type: grant_type, extra: extra)
    with_headers(auth_headers(token)) { yield }
  end

  # Encode/decode helpers for social callback state param
  def encode_state_redirect(redirect_uri)
    Base64.urlsafe_encode64({ redirect_uri: redirect_uri }.to_json)
  end

  # JSON body parser convenience
  def json_body
    JSON.parse(response.body)
  rescue JSON::ParserError
    {}
  end
end

RSpec.configure do |config|
  config.include RequestSpecHelpers, type: :request
end
