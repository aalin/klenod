# frozen_string_literal: true

root = File.expand_path(__dir__)
version = File.read(File.expand_path("../../KLENOD_VERSION", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name = "klenod-lsp"
  spec.version = version
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Language server for Klenod applications."
  spec.description = "Editor diagnostics and navigation for Klenod Haml modules over the Language Server Protocol."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod/tree/main/gems/klenod-lsp"

  spec.files =
    Dir.chdir(root) do
      ["README.md", *Dir["lib/**/*.rb"].reject { |path| path.end_with?(".test.rb") || path.include?("/__test__/") }]
    end
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-build", "= #{version}"
  spec.add_dependency "language_server-protocol", "~> 3.17"
end
