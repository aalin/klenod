# frozen_string_literal: true

root = File.expand_path(__dir__)
require File.expand_path("../klenod-runtime/lib/klenod/version", __dir__)

Gem::Specification.new do |spec|
  spec.name = "klenod-rack"
  spec.version = Klenod::VERSION
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Rack asset serving helpers for Klenod."
  spec.description = "Klenod Rack serves content-hashed runtime bundle assets from Rack-compatible applications."
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

  spec.add_dependency "klenod-runtime", "= #{Klenod::VERSION}"
end
