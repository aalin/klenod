# frozen_string_literal: true

root = File.expand_path(__dir__)
version = File.read(File.expand_path("../../KLENOD_VERSION", __dir__)).strip
ruby_version = File.read(File.expand_path("../../.ruby-version", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name = "klenod-test"
  spec.version = version
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Test runner for Klenod applications."
  spec.description = "Framework-independent test selection, watch runs, and coverage for Klenod applications."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= #{ruby_version}"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod/tree/main/gems/klenod-test"

  spec.files =
    Dir.chdir(root) do
      ["README.md", *Dir["lib/**/*.rb"].reject { |path| path.end_with?(".test.rb") }]
    end
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-build", "= #{version}"
  spec.add_dependency "async-process", "~> 1.4"
  spec.add_dependency "covered", "~> 0.30"
end
