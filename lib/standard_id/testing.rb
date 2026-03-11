require "standard_id/testing/authentication_helpers"
require "standard_id/testing/request_helpers"

module StandardId
  module Testing
    # Load StandardId's FactoryBot factory definitions.
    #
    # Requires the `factory_bot` (or `factory_bot_rails`) gem in the host app's
    # Gemfile under the :test group.
    #
    # Recommended usage in rails_helper.rb:
    #
    #   require "standard_id/testing"
    #   StandardId::Testing.setup_factory_bot!
    #
    def self.setup_factory_bot!
      require "standard_id/testing/factory_bot"
    rescue LoadError => e
      raise unless e.message.include?("factory_bot")

      raise LoadError,
        "StandardId::Testing.setup_factory_bot! requires the `factory_bot` gem. " \
        "Add `gem 'factory_bot_rails'` (or `gem 'factory_bot'`) to your Gemfile's :test group."
    end
  end
end
