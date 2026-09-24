require "rails_helper"

# Shared helpers plugin providers (standard_id-google, standard_id-apple) use
# instead of each re-implementing them. They are protected class methods, so
# the examples drive them through a subclass's public method, exactly as a
# plugin would.
RSpec.describe StandardId::Providers::Base, "plugin helpers" do
  let(:provider) do
    Class.new(described_class) do
      class << self
        def provider_name = "helper_test"
        def supported_authorization_params = %i[nonce scope prompt]

        def url(**kwargs) = build_authorization_url(**kwargs)
        def tokens(parsed) = extract_tokens(parsed)
        def nonce!(**kwargs) = verify_nonce!(**kwargs)
        def wrap(prefix = nil, &block) = rescue_to_oauth_error(prefix, &block)
      end
    end
  end

  describe ".rescue_to_oauth_error" do
    it "returns the block's value" do
      expect(provider.wrap { 42 }).to eq(42)
    end

    it "re-raises StandardId::OAuthError subclasses unchanged" do
      error = StandardId::InvalidRequestError.new("bad request")

      expect { provider.wrap { raise error } }.to raise_error(error)
    end

    it "wraps other errors in StandardId::OAuthError and keeps the cause" do
      expect { provider.wrap { raise JSON::ParserError, "unexpected token" } }
        .to raise_error(StandardId::OAuthError, "unexpected token") { |e|
          expect(e).to be_an_instance_of(StandardId::OAuthError)
          expect(e.cause).to be_a(JSON::ParserError)
        }
    end

    it "prefixes the wrapped message when given a prefix" do
      expect { provider.wrap("Failed to fetch JWK") { raise SocketError, "getaddrinfo" } }
        .to raise_error(StandardId::OAuthError, "Failed to fetch JWK: getaddrinfo")
    end

    it "is not callable from outside the provider" do
      expect { provider.rescue_to_oauth_error { 1 } }.to raise_error(NoMethodError)
    end
  end

  describe ".verify_nonce!" do
    it "is a no-op when no nonce was expected" do
      expect { provider.nonce!(expected: nil, actual: "whatever") }.not_to raise_error
      expect { provider.nonce!(expected: "", actual: nil) }.not_to raise_error
    end

    it "passes when the nonces match" do
      expect { provider.nonce!(expected: "n-123", actual: "n-123") }.not_to raise_error
    end

    it "raises InvalidRequestError on mismatch" do
      expect { provider.nonce!(expected: "n-123", actual: "n-456") }
        .to raise_error(StandardId::InvalidRequestError, "ID token nonce mismatch")
    end

    it "raises when the token carries no nonce" do
      expect { provider.nonce!(expected: "n-123", actual: nil) }
        .to raise_error(StandardId::InvalidRequestError)
    end

    it "never echoes either nonce in the error message" do
      expect { provider.nonce!(expected: "secret-expected", actual: "attacker-supplied") }
        .to raise_error(StandardId::InvalidRequestError) { |e|
          expect(e.message).not_to include("secret-expected")
          expect(e.message).not_to include("attacker-supplied")
        }
    end
  end

  describe ".build_authorization_url" do
    it "builds the base query then one entry per supported param, dropping nils" do
      url = provider.url(
        endpoint: "https://idp.example.com/authorize",
        client_id: "client-1",
        redirect_uri: "https://app.example.com/cb",
        state: "st",
        options: { nonce: "n1", unsupported: "ignored" },
        defaults: { scope: "openid email" }
      )

      uri = URI(url)
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://idp.example.com/authorize")
      expect(URI.decode_www_form(uri.query)).to eq([
        %w[client_id client-1],
        %w[redirect_uri https://app.example.com/cb],
        %w[response_type code],
        %w[state st],
        %w[nonce n1],
        ["scope", "openid email"]
      ])
    end

    it "lets caller options override defaults" do
      url = provider.url(
        endpoint: "https://idp.example.com/authorize", client_id: "c", redirect_uri: "r", state: "s",
        options: { scope: "openid" }, defaults: { scope: "openid email" }
      )

      expect(URI.decode_www_form(URI(url).query).to_h["scope"]).to eq("openid")
    end

    it "supports a custom response_type" do
      url = provider.url(endpoint: "https://idp.example.com/a", client_id: "c", redirect_uri: "r", state: "s",
                         response_type: "code id_token")

      expect(URI.decode_www_form(URI(url).query).to_h["response_type"]).to eq("code id_token")
    end
  end

  describe ".extract_tokens" do
    it "picks access, refresh and id tokens and drops missing ones" do
      parsed = { "access_token" => "at", "id_token" => "it", "token_type" => "Bearer", "expires_in" => 3600 }

      expect(provider.tokens(parsed)).to eq(access_token: "at", id_token: "it")
    end

    it "accepts symbol keys" do
      expect(provider.tokens(refresh_token: "rt")).to eq(refresh_token: "rt")
    end
  end
end
