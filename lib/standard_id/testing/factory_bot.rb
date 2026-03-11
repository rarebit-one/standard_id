require "factory_bot"

# Factories are loaded alphabetically via glob. FactoryBot resolves associations
# lazily, so load order does not affect correctness. If adding a factory file
# with an explicit dependency on another, use require_relative instead.
factory_paths = Dir[File.join(__dir__, "factories", "*.rb")]
factory_paths.each { |f| require f }
