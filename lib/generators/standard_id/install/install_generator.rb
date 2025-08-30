require "rails/generators"

module StandardId
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Creates a StandardId initializer at config/initializers/standard_id.rb"

      def create_initializer_file
        template "standard_id.rb", "config/initializers/standard_id.rb"
      end
    end
  end
end
