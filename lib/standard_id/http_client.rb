require "ipaddr"
require "net/http"
require "openssl"
require "resolv"
require "uri"

module StandardId
  class HttpClient
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    class SsrfError < StandardError; end

    BLOCKED_IP_RANGES = [
      IPAddr.new("10.0.0.0/8"),
      IPAddr.new("172.16.0.0/12"),
      IPAddr.new("192.168.0.0/16"),
      IPAddr.new("127.0.0.0/8"),
      IPAddr.new("169.254.0.0/16"),
      IPAddr.new("0.0.0.0/8"),
      IPAddr.new("::1/128"),
      IPAddr.new("fc00::/7"),
      IPAddr.new("fe80::/10")
    ].freeze

    # Provider name passed to `StandardId.config.network_wrapper` when a caller
    # does not name one.
    DEFAULT_PROVIDER = :standard_id

    class << self
      # `provider:` names the remote service (`:google`, `:apple`, ...) for
      # `StandardId.config.network_wrapper`, e.g. to keep one circuit per
      # provider. It has no other effect on the request.
      #
      # The form may also come as bare keywords (`post_form(url, id_token: t)`),
      # which is how callers written before `provider:` existed pass it: once
      # the method takes a keyword, Ruby reads a braceless Hash as keywords, so
      # `**form` keeps those calls working. A form field named `provider` must
      # therefore go in an explicit Hash. With no bare keywords, `params` goes
      # to `set_form_data` as given, so an Array of pairs keeps repeated keys.
      def post_form(endpoint, params = nil, provider: DEFAULT_PROVIDER, **form)
        uri, resolved_ip = validate_url!(endpoint)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(form.empty? ? (params || {}) : (params || {}).to_h.merge(form))
        start_connection(uri, resolved_ip:, provider:) { |http| http.request(request) }
      end

      def get_with_bearer(endpoint, access_token, provider: DEFAULT_PROVIDER)
        uri, resolved_ip = validate_url!(endpoint)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{access_token}"
        start_connection(uri, resolved_ip:, provider:) { |http| http.request(request) }
      end

      private

      def validate_url!(url)
        uri = URI.parse(url.to_s)
        raise SsrfError, "Only http and https schemes are allowed" unless %w[http https].include?(uri.scheme)
        raise SsrfError, "Invalid URL: missing host" if uri.host.nil? || uri.host.empty?

        addresses = Resolv.getaddresses(uri.host)
        raise SsrfError, "Could not resolve host" if addresses.empty?

        addresses.each do |addr|
          ip = IPAddr.new(addr)
          if BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
            raise SsrfError, "Requests to private/internal addresses are not allowed"
          end
        end

        # Return resolved IP to pin connection and prevent DNS rebinding
        [uri, addresses.first]
      end

      # Private, but provider plugins call it through `send` to fetch a JWKS
      # with a plain GET, so its signature is part of the plugin contract:
      # `provider:` is optional and new keywords must stay optional.
      #
      # The host's `network_wrapper` sees the whole connection (connect,
      # request, response), so a timeout or refused connection raises inside
      # it and reaches the caller as is; an error the wrapper raises itself
      # becomes StandardId::ProviderUnavailableError (see NetworkWrapper).
      def start_connection(uri, resolved_ip: nil, provider: DEFAULT_PROVIDER, &block)
        NetworkWrapper.run(provider:) { open_connection(uri, resolved_ip:, &block) }
      end

      def open_connection(uri, resolved_ip: nil, &block)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        # Pin to the resolved IP for SSRF/DNS-rebinding protection while
        # preserving the original hostname for TLS SNI and cert verification.
        http.ipaddr = resolved_ip if resolved_ip
        http.start(&block)
      end
    end
  end
end
