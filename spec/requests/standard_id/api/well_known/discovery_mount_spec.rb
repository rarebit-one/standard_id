require "rails_helper"

# The mount-prefix defect and its fix.
#
# The dummy app mounts ApiEngine at `/api`, which is exactly the broken case:
# endpoints derived from a bare-root issuer 404, because they actually live under
# the mount.
RSpec.describe "Discovery documents and the ApiEngine mount prefix", type: :request do
  let(:issuer) { "https://auth.example.com" }

  before { allow(StandardId.config).to receive(:issuer).and_return(issuer) }

  # Both documents share one builder, so both are exercised everywhere it
  # matters — the OIDC document had the identical bug.
  ENGINE_PATHS = {
    "RFC 8414 (oauth-authorization-server)" => "/api/.well-known/oauth-authorization-server",
    "OIDC (openid-configuration)" => "/api/.well-known/openid-configuration"
  }.freeze

  ROOT_PATHS = {
    "RFC 8414 at the origin root" => "/.well-known/oauth-authorization-server",
    "RFC 8414 §3.1 path-inserted" => "/.well-known/oauth-authorization-server/api",
    "OIDC at the origin root" => "/.well-known/openid-configuration",
    "OIDC §3.1 path-inserted" => "/.well-known/openid-configuration/api"
  }.freeze

  describe "default behaviour (discovery_endpoint_base unset)" do
    # The hard backward-compatibility requirement: every consuming app is on
    # 0.32.0 and must keep working with no code change, so the DEFAULT document
    # has to stay byte-identical.
    ENGINE_PATHS.each do |label, path|
      it "#{label} still derives endpoints from the issuer" do
        get path

        body = response.parsed_body
        expect(body["issuer"]).to eq(issuer)
        expect(body["token_endpoint"]).to eq("#{issuer}/oauth/token")
        expect(body["authorization_endpoint"]).to eq("#{issuer}/authorize")
        expect(body["revocation_endpoint"]).to eq("#{issuer}/oauth/revoke")
      end
    end

    it "emits no override-only members" do
      get ENGINE_PATHS.values.first

      expect(response.parsed_body).not_to have_key("scopes_supported")
    end
  end

  describe "discovery_endpoint_base = :request" do
    before { allow(StandardId.config.oauth).to receive(:discovery_endpoint_base).and_return(:request) }

    ENGINE_PATHS.each do |label, path|
      # Inside the mount, Rails sets SCRIPT_NAME to the mount prefix, so the
      # mount path needs no detection or configuration — it is read off the
      # request exactly.
      it "#{label} advertises endpoints under the mount, read off SCRIPT_NAME" do
        get path

        body = response.parsed_body
        expect(body["token_endpoint"]).to eq("http://www.example.com/api/oauth/token")
        expect(body["authorization_endpoint"]).to eq("http://www.example.com/api/authorize")
        expect(body["revocation_endpoint"]).to eq("http://www.example.com/api/oauth/revoke")
      end

      it "#{label} leaves the issuer byte-identical" do
        get path

        expect(response.parsed_body["issuer"]).to eq(issuer)
      end
    end

    ROOT_PATHS.each do |label, path|
      # A root route is outside every engine mount, so there is no SCRIPT_NAME to
      # read. The routing helper stamps the mount path into the route defaults
      # instead, and the resolver reads it back.
      it "#{label} resolves the mount path from the route defaults" do
        get path

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["issuer"]).to eq(issuer)
        expect(body["token_endpoint"]).to eq("http://www.example.com/api/oauth/token")
      end
    end

    # The gem's own optional endpoints must move with the base too, or enabling
    # introspection/DCR under a prefixed mount advertises two more 404s.
    it "moves the gem's own optional endpoints under the mount as well" do
      allow(StandardId.config.oauth).to receive(:introspection_enabled).and_return(true)
      allow(StandardId.config.oauth).to receive(:dynamic_registration_enabled).and_return(true)

      get ENGINE_PATHS.values.first

      body = response.parsed_body
      expect(body["introspection_endpoint"]).to eq("http://www.example.com/api/oauth/introspect")
      expect(body["registration_endpoint"]).to eq("http://www.example.com/api/oauth/register")
    end

    it "accepts the string form as well as the symbol" do
      allow(StandardId.config.oauth).to receive(:discovery_endpoint_base).and_return("request")

      get ENGINE_PATHS.values.first

      expect(response.parsed_body["token_endpoint"]).to eq("http://www.example.com/api/oauth/token")
    end
  end

  describe "discovery_endpoint_base as an explicit string" do
    it "is used verbatim, without touching the issuer" do
      allow(StandardId.config.oauth)
        .to receive(:discovery_endpoint_base).and_return("https://gateway.example.com/oauth-api/")

      get ENGINE_PATHS.values.first

      body = response.parsed_body
      expect(body["issuer"]).to eq(issuer)
      expect(body["token_endpoint"]).to eq("https://gateway.example.com/oauth-api/oauth/token")
    end
  end

  describe "discovery_endpoint_base as a callable" do
    it "receives the request, for proxies that rewrite base_url" do
      seen = nil
      resolver = ->(request:) {
        seen = request
        "https://public.example.com/api"
      }
      allow(StandardId.config.oauth).to receive(:discovery_endpoint_base).and_return(resolver)

      get ENGINE_PATHS.values.first

      expect(seen).to be_a(ActionDispatch::Request)
      expect(response.parsed_body["token_endpoint"]).to eq("https://public.example.com/api/oauth/token")
    end

    it "falls back to the issuer when the callable returns blank" do
      allow(StandardId.config.oauth).to receive(:discovery_endpoint_base).and_return(->(request:) { nil })

      get ENGINE_PATHS.values.first

      expect(response.parsed_body["token_endpoint"]).to eq("#{issuer}/oauth/token")
    end
  end

  describe "discovery_metadata_overrides" do
    def with_overrides(overrides)
      allow(StandardId.config.oauth).to receive(:discovery_metadata_overrides).and_return(overrides)
    end

    it "replaces a member with a static value (a deliberately narrowed scope list)" do
      with_overrides(scopes_supported: %w[mcp mcp:read])

      get ENGINE_PATHS.values.first

      expect(response.parsed_body["scopes_supported"]).to eq(%w[mcp mcp:read])
    end

    it "narrows token_endpoint_auth_methods_supported, so it can mirror a DCR policy" do
      with_overrides(token_endpoint_auth_methods_supported: %w[none])

      get ENGINE_PATHS.values.first

      expect(response.parsed_body["token_endpoint_auth_methods_supported"]).to eq(%w[none])
    end

    it "REMOVES a member when the value is nil, rather than emitting null" do
      with_overrides(grant_types_supported: nil, userinfo_endpoint: nil)

      get ENGINE_PATHS.values.first

      body = response.parsed_body
      expect(body).not_to have_key("grant_types_supported")
      expect(body).not_to have_key("userinfo_endpoint")
    end

    it "evaluates a callable with origin, endpoint_base, issuer and request" do
      captured = nil
      with_overrides(
        authorization_endpoint: ->(ctx) {
          captured = ctx
          "#{ctx[:origin]}/oauth/authorize"
        }
      )

      get ENGINE_PATHS.values.first

      # The redirect-to-a-host-shim case: all five consuming apps need this,
      # because the engine's own /authorize does not inject the audience an MCP
      # client's token needs.
      expect(response.parsed_body["authorization_endpoint"])
        .to eq("http://www.example.com/oauth/authorize")
      expect(captured[:origin]).to eq("http://www.example.com")
      expect(captured[:issuer]).to eq(issuer)
      expect(captured[:endpoint_base]).to eq(issuer)
      expect(captured[:request]).to be_a(ActionDispatch::Request)
    end

    it "adds a member the gem does not derive at all" do
      with_overrides(introspection_endpoint: "https://auth.example.com/oauth/introspect")

      get ENGINE_PATHS.values.first

      expect(response.parsed_body["introspection_endpoint"])
        .to eq("https://auth.example.com/oauth/introspect")
    end

    it "accepts string keys as well as symbols" do
      with_overrides("scopes_supported" => %w[mcp])

      get ENGINE_PATHS.values.first

      expect(response.parsed_body["scopes_supported"]).to eq(%w[mcp])
    end

    # The issuer is a security identifier clients match byte-for-byte against
    # both their discovery URL and the `iss` claim. An override that diverged it
    # from what the token service stamps would yield a document validating
    # against nothing, failing far from its cause.
    it "REFUSES to set the issuer" do
      expect {
        StandardId::Oauth::DiscoveryDocument.build(issuer, overrides: { issuer: "https://evil.example.com" })
      }.to raise_error(StandardId::ConfigurationError, /cannot set `issuer`/)
    end

    it "points at discovery_endpoint_base in that error, so the fix is obvious" do
      expect {
        StandardId::Oauth::DiscoveryDocument.build(issuer, overrides: { "issuer" => "https://evil.example.com" })
      }.to raise_error(/discovery_endpoint_base/)
    end
  end

  describe "the routing helper" do
    it "draws both the root and the RFC 8414 §3.1 path-inserted form" do
      routes = Rails.application.routes.routes.map { |r| r.path.spec.to_s }

      expect(routes).to include("/.well-known/oauth-authorization-server(.:format)")
      expect(routes).to include("/.well-known/oauth-authorization-server/api(.:format)")
      expect(routes).to include("/.well-known/openid-configuration(.:format)")
      expect(routes).to include("/.well-known/openid-configuration/api(.:format)")
    end

    it "draws JWKS at the root" do
      get "/.well-known/jwks.json"

      # 404 under symmetric signing is the correct answer (no public keys to
      # publish); what matters here is that the route resolves at all.
      expect(response.status).to be_in([200, 404])
    end

    it "does not draw a path-inserted JWKS, which no spec describes" do
      routes = Rails.application.routes.routes.map { |r| r.path.spec.to_s }

      expect(routes).not_to include("/.well-known/jwks.json/api(.:format)")
    end
  end

  describe "StandardId::Routing.selected_documents" do
    it "returns every document by default" do
      expect(StandardId::Routing.selected_documents.keys)
        .to contain_exactly(:oauth_authorization_server, :openid_configuration, :jwks)
    end

    # Two apps keep a host-owned metadata controller but want the gem's JWKS at
    # the root.
    it "honours only:" do
      expect(StandardId::Routing.selected_documents(only: :jwks).keys).to eq([:jwks])
    end

    it "honours except:" do
      expect(StandardId::Routing.selected_documents(except: [:jwks]).keys)
        .to contain_exactly(:oauth_authorization_server, :openid_configuration)
    end

    it "rejects only: and except: together" do
      expect { StandardId::Routing.selected_documents(only: :jwks, except: :jwks) }
        .to raise_error(ArgumentError, /not both/)
    end

    it "names the valid documents when given an unknown one" do
      expect { StandardId::Routing.selected_documents(only: :nope) }
        .to raise_error(ArgumentError, /Unknown StandardId well-known document/)
    end
  end

  describe "StandardId::Oauth::DiscoveryResolver.normalize_path" do
    it "never yields a trailing slash or a bare slash, so concatenation is safe" do
      resolver = StandardId::Oauth::DiscoveryResolver

      expect(resolver.normalize_path("/")).to eq("")
      expect(resolver.normalize_path("")).to eq("")
      expect(resolver.normalize_path(nil)).to eq("")
      expect(resolver.normalize_path("api")).to eq("/api")
      expect(resolver.normalize_path("/api/")).to eq("/api")
      expect(resolver.normalize_path("/api/v1")).to eq("/api/v1")
    end
  end
  # End-to-end proof that the new surface reproduces a real app's hand-rolled
  # document, so the local controller can actually be deleted. Modelled on
  # sidekick-web's, which is the most demanding of the five (a prefixed mount, an
  # override-only introspection endpoint, a root JWKS, and four narrowings).
  describe "reproducing a consuming app's hand-rolled document" do
    before do
      allow(StandardId.config.oauth).to receive(:discovery_endpoint_base).and_return(:request)
      allow(StandardId.config.oauth).to receive(:discovery_metadata_overrides).and_return(
        authorization_endpoint: ->(ctx) { "#{ctx[:origin]}/oauth/authorize" },
        registration_endpoint: ->(ctx) { "#{ctx[:origin]}/oauth/register" },
        introspection_endpoint: ->(ctx) { "#{ctx[:endpoint_base]}/oauth/introspect" },
        jwks_uri: ->(ctx) { "#{ctx[:origin]}/.well-known/jwks.json" },
        grant_types_supported: %w[authorization_code refresh_token],
        token_endpoint_auth_methods_supported: %w[none client_secret_basic client_secret_post],
        scopes_supported: %w[mcp mcp:read],
        userinfo_endpoint: nil,
        subject_types_supported: nil,
        id_token_signing_alg_values_supported: nil
      )
    end

    it "emits exactly the members the app's own controller emitted" do
      get "/.well-known/oauth-authorization-server"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "issuer" => issuer,
        "authorization_endpoint" => "http://www.example.com/oauth/authorize",
        "token_endpoint" => "http://www.example.com/api/oauth/token",
        "revocation_endpoint" => "http://www.example.com/api/oauth/revoke",
        "introspection_endpoint" => "http://www.example.com/api/oauth/introspect",
        "registration_endpoint" => "http://www.example.com/oauth/register",
        "jwks_uri" => "http://www.example.com/.well-known/jwks.json",
        "response_types_supported" => ["code"],
        "grant_types_supported" => %w[authorization_code refresh_token],
        "token_endpoint_auth_methods_supported" => %w[none client_secret_basic client_secret_post],
        "code_challenge_methods_supported" => ["S256"],
        "scopes_supported" => %w[mcp mcp:read]
      )
    end

    it "serves the identical document from the RFC 8414 §3.1 path-inserted route" do
      get "/.well-known/oauth-authorization-server"
      root = response.parsed_body

      get "/.well-known/oauth-authorization-server/api"

      expect(response.parsed_body).to eq(root)
    end
  end
end
