# frozen_string_literal: true

root = File.expand_path(__dir__)
version = File.read(File.expand_path("../../KLENOD_VERSION", __dir__)).strip
ruby_version = File.read(File.expand_path("../../.ruby-version", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name = "klenod-runtime"
  spec.version = version
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Production runtime for Klenod bundles."
  spec.description = "Production runtime for Klenod."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= #{ruby_version}"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod/tree/main/gems/klenod-runtime"

  spec.files =
    Dir.chdir(root) do
      ["README.md", *Dir["lib/**/*.rb"]].select { |path| File.file?(path) && !path.end_with?(".test.rb") }
    end
  spec.require_paths = ["lib"]
end
