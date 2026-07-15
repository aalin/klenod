# frozen_string_literal: true

root = File.expand_path(__dir__)
version = File.read(File.expand_path("../../VERSION", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name = "klenod"
  spec.version = version
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Experimental Ruby module bundler."
  spec.description = "Compatibility gem for Klenod build, runtime, and Rack packages."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod"

  spec.files = Dir.chdir(root) { ["README.md", *Dir["lib/**/*.rb"].reject { |path| path.end_with?(".test.rb") }, "exe/klenod"] }
  spec.bindir = "exe"
  spec.executables = ["klenod"]
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-build", "= #{version}"
  spec.add_dependency "klenod-rack", "= #{version}"
end
