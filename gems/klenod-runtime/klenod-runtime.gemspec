# frozen_string_literal: true

root = File.expand_path(__dir__)
require File.join(root, "lib/klenod/version")

Gem::Specification.new do |spec|
  spec.name = "klenod-runtime"
  spec.version = Klenod::VERSION
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Runtime loader for Klenod bundles."
  spec.description = "Klenod runtime loads serialized Ruby module bundles without build plugins or development dependencies."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod"

  spec.files =
    Dir.chdir(root) do
      Dir["lib/**/*.rb"].select { |path| File.file?(path) && !path.end_with?(".test.rb") }
    end
  spec.require_paths = ["lib"]
end
