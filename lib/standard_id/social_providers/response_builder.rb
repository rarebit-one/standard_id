require "active_support/concern"

module StandardId
  module SocialProviders
    module ResponseBuilder
      extend ActiveSupport::Concern

      class_methods do
        def build_response(user_info, tokens: {})
          {
            user_info: user_info,
            tokens: tokens.compact
          }.with_indifferent_access
        end
      end
    end
  end
end
