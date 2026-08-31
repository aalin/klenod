# frozen_string_literal: true

root = File.expand_path(__dir__)
version = File.read(File.expand_path("../../KLENOD_VERSION", __dir__)).strip
ruby_version = File.read(File.expand_path("../../.ruby-version", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name = "klenod-rack"
  spec.version = version
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Rack asset serving helpers for Klenod."
  spec.description = "Rack-compatible asset serving helpers for Klenod."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= #{ruby_version}"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod/tree/main/gems/klenod-rack"

  spec.files =
    Dir.chdir(root) do
      ["README.md", *Dir["lib/**/*.rb"]].select { |path| File.file?(path) && !path.end_with?(".test.rb") }
    end
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-runtime", "= #{version}"
  spec.add_dependency "http-accept", "~> 2.2"
end
