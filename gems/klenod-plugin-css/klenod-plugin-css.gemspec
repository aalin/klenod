# frozen_string_literal: true

root = File.expand_path(__dir__)
version = File.read(File.expand_path("../../KLENOD_VERSION", __dir__)).strip
ruby_version = File.read(File.expand_path("../../.ruby-version", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name = "klenod-plugin-css"
  spec.version = version
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "CSS plugin for Klenod."
  spec.description = "CSS asset and CSS Modules plugin for Klenod."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= #{ruby_version}"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod/tree/main/gems/klenod-plugin-css"

  spec.files =
    Dir.chdir(root) do
      [
        "README.md",
        *Dir["lib/**/*.rb"],
        *Dir["ext/native/Cargo.*"],
        "ext/native/extconf.rb",
        *Dir["ext/native/src/**/*.rs"]
      ].select do |path|
        File.file?(path) &&
          !path.end_with?(".test.rb") &&
          !path.include?("/__test__/")
      end
    end
  spec.extensions = ["ext/native/extconf.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-build", "= #{version}"
  spec.add_dependency "rb_sys", "~> 0.9.124"

  spec.add_development_dependency "rake-compiler", "~> 1.3"
end
