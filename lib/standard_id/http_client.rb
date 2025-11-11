require "net/http"
require "uri"

module StandardId
  class HttpClient
    class << self
      def post_form(endpoint, params)
        uri = URI(endpoint)
        Net::HTTP.post_form(uri, params)
      end

      def get_with_bearer(endpoint, access_token)
        uri = URI(endpoint)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{access_token}"
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end
      end
    end
  end
end
