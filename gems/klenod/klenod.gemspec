# frozen_string_literal: true

root = File.expand_path("../..", __dir__)
require File.join(root, "lib/klenod/version")

Gem::Specification.new do |spec|
  spec.name = "klenod"
  spec.version = Klenod::VERSION
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Experimental Ruby module bundler."
  spec.description = "Compatibility gem for Klenod build, runtime, and Rack packages."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod"

  spec.files = ["lib/klenod.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-build", "= #{Klenod::VERSION}"
  spec.add_dependency "klenod-rack", "= #{Klenod::VERSION}"
end
