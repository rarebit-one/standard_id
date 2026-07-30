# Stands in for a provider plugin gem (standard_id-google, standard_id-apple).
#
# Required from config/application.rb, i.e. at the same point in boot a plugin's
# entry file requires its provider class — BEFORE any initializer runs, and
# before the plugin's own Railtie `after_initialize` registers it. That timing is
# the whole reason this file exists: it makes the dummy app exercise the exact
# boot order that used to raise, so the guarantee is enforced by whether the app
# BOOTS rather than by an assertion someone could delete.
#
# See config/initializers/dummy_provider_config.rb, which writes this provider's
# fields the way the install template tells host apps to.
require "standard_id"

module StandardId
  module Providers
    class DummySocial < Base
      class << self
        def provider_name
          "dummy_social"
        end

        def authorization_url(state:, redirect_uri:, **_options)
          "https://dummy.example.com/auth?state=#{state}&redirect_uri=#{redirect_uri}"
        end

        def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, **_options)
          { user_info: { "sub" => "dummy_user" }, tokens: {} }.with_indifferent_access
        end

        def config_schema
          {
            dummy_social_client_id: { type: :string, default: nil },
            dummy_social_client_secret: { type: :string, default: nil }
          }
        end
      end
    end
  end
end
