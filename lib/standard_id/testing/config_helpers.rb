module StandardId
  module Testing
    # Helpers for specs that exercise StandardId configuration defaults —
    # chiefly the ENV fallback of provider fields (`GOOGLE_CLIENT_ID`,
    # `APPLE_CLIENT_ID`, …).
    #
    # Those defaults are resolved ONCE, when the config is built at boot, so
    # setting ENV inside a spec changes nothing on its own. `with_provider_env`
    # sets the variables, re-resolves every field the host never assigned, runs
    # the block, then restores both:
    #
    #   RSpec.describe "Apple sign-in" do
    #     include StandardId::Testing::ConfigHelpers
    #
    #     it "is enabled once APPLE_CLIENT_ID is set" do
    #       with_provider_env("APPLE_CLIENT_ID" => "com.example.web") do
    #         expect(StandardId.social_provider_enabled?(:apple)).to be(true)
    #       end
    #     end
    #   end
    #
    # (also callable as `StandardId::Testing.with_provider_env(...)`).
    #
    # A field the host assigned explicitly — even to nil — ignores ENV by
    # design; `StandardId.config.social.assigned?(:apple_client_id)` tells the
    # two cases apart (`key?` is true for every declared field, assigned or
    # not).
    module ConfigHelpers
      # @param env [Hash{String => String, nil}] variables to set; nil unsets.
      #   Usually passed brace-less (`with_provider_env("APPLE_CLIENT_ID" => "x")`),
      #   which Ruby delivers as keywords — hence **vars.
      # @param scope [Symbol] config scope whose defaults to re-resolve
      # @yield with the variables set and the scope's defaults re-resolved
      # @return [Object] the block's value
      def with_provider_env(env = {}, scope: :social, **vars)
        env = env.merge(vars)
        previous = env.to_h { |name, _| [name.to_s, ENV[name.to_s]] }
        env.each { |name, value| write_env(name.to_s, value) }
        StandardId.config[scope].refresh_defaults!
        yield
      ensure
        previous&.each { |name, value| write_env(name, value) }
        StandardId.config[scope].refresh_defaults!
      end

      private

      def write_env(name, value)
        value.nil? ? ENV.delete(name) : ENV[name] = value.to_s
      end
    end

    extend ConfigHelpers
  end
end
