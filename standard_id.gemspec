require_relative "lib/standard_id/version"

Gem::Specification.new do |spec|
  spec.name        = "standard_id"
  spec.version     = StandardId::VERSION
  spec.authors     = [ "Jaryl Sim" ]
  spec.email       = [ "code@jaryl.dev" ]
  spec.homepage    = "https://github.com/rarebit-one/standard_id"
  spec.summary     = "A comprehensive authentication engine for Rails, built on the security primitives introduced in Rails 7/8."
  spec.description = "StandardId is an authentication engine that provides a complete, secure-by-default solution for identity management, reducing boilerplate and eliminating common security pitfalls."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rarebit-one/standard_id"
  spec.metadata["changelog_uri"] = "https://github.com/rarebit-one/standard_id/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0.2"
  spec.add_dependency "bcrypt", "~> 3.1.7"
end
