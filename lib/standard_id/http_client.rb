require "net/http"
require "uri"

module StandardId
  class HttpClient
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    class << self

      def post_form(endpoint, params)
        uri = URI(endpoint)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(params)
        http.request(request)
      end

      def get_with_bearer(endpoint, access_token)
        uri = URI(endpoint)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{access_token}"
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                             open_timeout: OPEN_TIMEOUT,
                                             read_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end
      end
    end
  end
end
