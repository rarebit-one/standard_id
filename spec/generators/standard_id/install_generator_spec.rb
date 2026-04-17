require "rails_helper"
require "generators/standard_id/install/install_generator"
require "rails/generators"

RSpec.describe StandardId::Generators::InstallGenerator, type: :generator do
  let(:destination_root) { File.expand_path("../../../tmp/generator_dest", __dir__) }
  let(:initializer_path) { File.join(destination_root, "config/initializers/standard_id.rb") }
  let(:routes_path) { File.join(destination_root, "config/routes.rb") }

  # Tracks every call made to the configured migration task runner so specs
  # can assert it did (or did not) fire.
  let(:migration_runner_calls) { [] }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(routes_path, <<~RB)
      Rails.application.routes.draw do
        root "home#index"
      end
    RB

    # Replace the migration task runner so specs don't shell out to
    # `rake standard_id:install:migrations`. Restored in the after hook.
    @original_runner = described_class.migration_task_runner
    described_class.migration_task_runner = ->(_g) { migration_runner_calls << true }
  end

  after do
    described_class.migration_task_runner = @original_runner
  end

  def run_generator(args = [])
    captured = StringIO.new
    original_stdout = $stdout
    $stdout = captured
    described_class.start(args, destination_root: destination_root)
    captured.string
  ensure
    $stdout = original_stdout
  end

  describe "happy path" do
    it "creates the initializer with the new section structure" do
      run_generator

      expect(File).to exist(initializer_path)
      content = File.read(initializer_path)

      expect(content).to include("StandardId.configure do |c|")
      expect(content).to include("c.account_class_name = \"User\"")
      # Section headers we care about
      expect(content).to include("# Required")
      expect(content).to include("# Web engine feature toggles")
      expect(content).to include("# Passwordless (OTP)")
      expect(content).to include("# Lifecycle hooks")
    end

    it "appends engine mount lines inside the routes block" do
      run_generator

      content = File.read(routes_path)
      expect(content).to include('mount StandardId::WebEngine => "/"')
      expect(content).to include('mount StandardId::ApiEngine => "/api"')
      # The commented-out scoped mount example should be present
      expect(content).to include("scope \"/api/:api_version\"")
      # And the original content is preserved
      expect(content).to include('root "home#index"')
    end

    it "invokes the engine migration copy rake task" do
      run_generator
      expect(migration_runner_calls.length).to eq(1)
    end

    it "prints the post-install checklist" do
      output = run_generator

      expect(output).to include("StandardId installed.")
      expect(output).to include("include StandardId::AccountAssociations")
      expect(output).to include("include StandardId::WebAuthentication")
      expect(output).to include("include StandardId::ApiAuthentication")
      expect(output).to include("StandardId::CleanupExpiredSessionsJob")
      expect(output).to include("bin/rails db:migrate")
    end
  end

  describe "idempotency" do
    it "does not duplicate the engine mount lines when run twice" do
      run_generator
      count_after_one = File.read(routes_path).scan(/mount StandardId::WebEngine/).length
      run_generator

      content = File.read(routes_path)
      # The snippet we inject includes commented-out scoped-mount examples
      # that themselves mention `mount StandardId::WebEngine`, so the absolute
      # count is > 1 after a single run. What matters for idempotency is that
      # running a second time does not increase it.
      expect(count_after_one).to be > 0
      expect(content.scan(/mount StandardId::WebEngine/).length).to eq(count_after_one)
      expect(content.scan(/^\s*mount StandardId::WebEngine => "\/"/).length).to eq(1)
      expect(content.scan(/^\s*mount StandardId::ApiEngine => "\/api"/).length).to eq(1)
    end

    it "announces that routes are already mounted on re-run" do
      run_generator
      output = run_generator

      expect(output).to match(/StandardId engines already mounted/)
    end
  end

  describe "flags" do
    it "--skip-initializer omits the initializer file" do
      run_generator(["--skip-initializer"])
      expect(File).not_to exist(initializer_path)
    end

    it "--skip-routes leaves routes.rb untouched" do
      run_generator(["--skip-routes"])
      content = File.read(routes_path)
      expect(content).not_to include("mount StandardId::WebEngine")
    end

    it "--skip-migrations avoids invoking the migration copy task" do
      run_generator(["--skip-migrations"])
      expect(migration_runner_calls).to be_empty
    end
  end

  describe "missing routes.rb" do
    it "warns instead of crashing" do
      FileUtils.rm(routes_path)
      output = run_generator
      expect(output).to match(/config\/routes\.rb not found/)
    end
  end
end
