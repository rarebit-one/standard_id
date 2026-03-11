module StandardId
  module Utils
    class IpNormalizer
      IPV6_LOCALHOST = "::1"
      IPV4_LOCALHOST = "127.0.0.1"

      class << self
        def normalize(ip)
          return ip unless ip == IPV6_LOCALHOST

          IPV4_LOCALHOST
        end
      end
    end
  end
end
