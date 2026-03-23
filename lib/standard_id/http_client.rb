require "ipaddr"
require "net/http"
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
      IPAddr.new("fd00::/8"),
      IPAddr.new("fe80::/10")
    ].freeze

    class << self
      def post_form(endpoint, params)
        uri = validate_url!(endpoint)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(params)
        start_connection(uri) { |http| http.request(request) }
      end

      def get_with_bearer(endpoint, access_token)
        uri = validate_url!(endpoint)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{access_token}"
        start_connection(uri) { |http| http.request(request) }
      end

      private

      def validate_url!(url)
        uri = URI.parse(url.to_s)
        addresses = Resolv.getaddresses(uri.host)

        addresses.each do |addr|
          ip = IPAddr.new(addr)
          if BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
            raise SsrfError, "Requests to private/internal addresses are not allowed"
          end
        end

        uri
      end

      def start_connection(uri, &block)
        options = {
          use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        }
        options[:verify_mode] = OpenSSL::SSL::VERIFY_PEER if options[:use_ssl]

        Net::HTTP.start(uri.host, uri.port, **options, &block)
      end
    end
  end
end
