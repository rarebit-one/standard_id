require "rails_helper"
require "generators/standard_id/install/install_generator"
require "rails/generators"

RSpec.describe StandardId::Generators::InstallGenerator, type: :generator do
  let(:destination_root) { File.expand_path("../../../tmp/generator_dest", __dir__) }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(destination_root)
  end

  it "creates the initializer with default content" do
    described_class.start([], destination_root: destination_root)

    path = File.join(destination_root, "config/initializers/standard_id.rb")
    expect(File.exist?(path)).to be(true)
    content = File.read(path)
    expect(content).to include("StandardId.configure do |c|")
    expect(content).to include("c.account_class_name = \"User\"")
  end
end
