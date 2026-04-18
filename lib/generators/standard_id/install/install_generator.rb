require "rails/generators"

module StandardId
  module Generators
    # Installs StandardId in a host Rails application.
    #
    # Creates the initializer, mounts the Web/Api engines in the host's
    # config/routes.rb, copies the engine's database migrations into the host,
    # and prints a post-install checklist with the remaining manual steps.
    #
    # Idempotent: re-running the generator will skip files/routes it has
    # already installed.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Installs StandardId. By default this:
          * writes config/initializers/standard_id.rb
          * mounts StandardId::WebEngine and StandardId::ApiEngine in config/routes.rb
          * copies the engine's migrations into db/migrate/

        Use --skip-* flags to opt out of individual steps when re-running on an
        existing install. The generator is idempotent — already-installed
        pieces are skipped with a clear message.
      DESC

      class_option :skip_initializer, type: :boolean, default: false,
        desc: "Do not write config/initializers/standard_id.rb"
      class_option :skip_routes, type: :boolean, default: false,
        desc: "Do not append engine mount lines to config/routes.rb"
      class_option :skip_migrations, type: :boolean, default: false,
        desc: "Do not copy StandardId migrations into db/migrate"

      def create_initializer_file
        return say_status("skip", "config/initializers/standard_id.rb (--skip-initializer)", :yellow) if options[:skip_initializer]

        template "standard_id.rb", "config/initializers/standard_id.rb"
      end

      def mount_engines
        return say_status("skip", "config/routes.rb (--skip-routes)", :yellow) if options[:skip_routes]

        routes_path = "config/routes.rb"
        unless File.exist?(File.join(destination_root, routes_path))
          say_status("warn", "#{routes_path} not found — add engine mounts manually", :red)
          return
        end

        if engines_already_mounted?(routes_path)
          say_status("identical", "#{routes_path} (StandardId engines already mounted)", :blue)
          return
        end

        inject_into_file routes_path, indent(engine_mount_snippet, 2), after: "Rails.application.routes.draw do\n"

        # inject_into_file silently no-ops when the `after:` string doesn't
        # match exactly (e.g. the host has a trailing comment or a rubocop
        # directive on the `draw do` line, or the file uses CRLF line
        # endings). Re-read and warn so the user isn't left with an
        # un-mounted engine.
        unless engines_already_mounted?(routes_path)
          say_status(
            "warn",
            "Could not auto-mount StandardId engines in #{routes_path}. " \
              "Add the following inside `Rails.application.routes.draw do` manually:\n" \
              "  mount StandardId::WebEngine => \"/\"\n" \
              "  mount StandardId::ApiEngine => \"/api\"",
            :red
          )
        end
      end

      def copy_migrations
        return say_status("skip", "db/migrate (--skip-migrations)", :yellow) if options[:skip_migrations]

        # The engine's namespace is `standard_id`, so Rails auto-registers
        # `standard_id:install:migrations`. We run it via a Rails command so
        # the host app's environment (and existing migrations) is honoured.
        run_migration_copy_task
      end

      def print_post_install_message
        say ""
        say "=" * 79
        say "StandardId installed."
        say ""
        say "To complete setup:"
        say ""
        say "1. Account model — add to app/models/account.rb (or your user model):"
        say ""
        say "     class Account < ApplicationRecord"
        say "       include StandardId::AccountAssociations"
        say "       include StandardId::AccountStatus"
        say "     end"
        say ""
        say "   AccountAssociations wires up :identifiers, :credentials, :sessions,"
        say "   :refresh_tokens, and :client_applications, plus nested attributes."
        say ""
        say "2. Controllers — include in relevant base controllers:"
        say ""
        say "     # app/controllers/application_controller.rb"
        say "     include StandardId::WebAuthentication"
        say ""
        say "     # app/controllers/api/base_controller.rb"
        say "     include StandardId::ApiAuthentication"
        say ""
        say "     # app/channels/application_cable/connection.rb"
        say "     include StandardId::CableAuthentication"
        say ""
        say "3. Configure — review config/initializers/standard_id.rb. Required:"
        say "     - account_class_name (defaults to \"User\" — change if your model is Account)"
        say "     - issuer             (your base URL; used as JWT \"iss\" claim)"
        say "     - oauth.allowed_audiences (array of audience names if enforcing JWT aud)"
        say ""
        say "4. Migrations — run:"
        say ""
        say "     bin/rails db:migrate"
        say ""
        say "5. Scheduled maintenance — schedule the cleanup jobs (e.g. daily):"
        say ""
        say "     StandardId::CleanupExpiredSessionsJob"
        say "     StandardId::CleanupExpiredRefreshTokensJob"
        say ""
        say "6. Social providers — install provider plugins and register them:"
        say ""
        say "     gem \"standard_id-google\""
        say "     gem \"standard_id-apple\""
        say ""
        say "   See the README section on providers for credential configuration."
        say ""
        say "Run `rails g standard_id:install --help` for options."
        say "=" * 79
        say ""
      end

      # Allow specs to swap in a no-op migration runner without relying on
      # RSpec stubs, which run afoul of Thor's `method_added` task registration
      # and `verify_partial_doubles` when applied to the inherited `rake`
      # shell action. Assign a callable: `generator_class.migration_task_runner = ->(_) { }`.
      class << self
        attr_accessor :migration_task_runner
      end
      self.migration_task_runner = ->(g) { g.send(:rake, "standard_id:install:migrations") }

      no_commands do
        def run_migration_copy_task
          self.class.migration_task_runner.call(self)
        end

        def engines_already_mounted?(routes_path)
          content = File.read(File.join(destination_root, routes_path))
          # Anchor to an uncommented line — a substring match would trigger on
          # a commented example copied from this generator's own template and
          # silently skip the real mount, leading to 404 routes.
          content.match?(/^\s*mount\s+StandardId::/)
        end

        def indent(text, spaces)
          prefix = " " * spaces
          text.each_line.map { |line| line.strip.empty? ? line : prefix + line }.join
        end

        def engine_mount_snippet
          <<~RUBY
            # Mount the StandardId engines. The web engine serves cookie-based
            # sessions (login, signup, password reset, OAuth authorization) while
            # the API engine serves JWT-based token endpoints.
            mount StandardId::WebEngine => "/"
            mount StandardId::ApiEngine => "/api"

            # Multi-tenant / scoped mounts — use instead of, or alongside, the
            # defaults above when you need multiple authentication entry points
            # or version the API under a path prefix.
            #
            # mount StandardId::WebEngine, at: "/auth/admin", as: :admin_auth, defaults: { scope: :admin }
            # mount StandardId::WebEngine, at: "/",           as: :standard_id_web, defaults: { scope: :user }
            #
            # scope "/api/:api_version", as: :api, module: :api, constraints: { api_version: /v\\d+/ } do
            #   mount StandardId::ApiEngine, at: "/", as: :standard_id_api
            # end

          RUBY
        end
      end
    end
  end
end
