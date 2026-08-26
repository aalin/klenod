# frozen_string_literal: true

root = File.expand_path(__dir__)
version = File.read(File.expand_path("../../KLENOD_VERSION", __dir__)).strip
ruby_version = File.read(File.expand_path("../../.ruby-version", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name = "klenod-build"
  spec.version = version
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Build graph and plugins for Klenod."
  spec.description = "Klenod build constructs Ruby module graphs, runs plugins, emits assets, and serializes runtime bundles."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= #{ruby_version}"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod/tree/main/gems/klenod-build"

  spec.files =
    Dir.chdir(root) do
      [
        "README.md",
        "lib/klenod/build.rb",
        "lib/klenod/build/cli.rb",
        "lib/klenod/build/watcher.rb",
        *Dir["lib/klenod/build/**/*.rb"],
        *Dir["lib/klenod/build/plugins/google_fonts_plugin/*.{json,txt}"]
      ].select do |path|
        File.file?(path) &&
          !path.end_with?(".test.rb") &&
          !path.include?("/__test__/") &&
          !path.end_with?("/test_support.rb")
      end
    end
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-runtime", "= #{version}"
  spec.add_dependency "async", "~> 2.42"
  spec.add_dependency "async-http", "~> 0.95.1"
  spec.add_dependency "brotli", "~> 0.8"
  spec.add_dependency "image_size", "~> 3.6"
  spec.add_dependency "kramdown", "~> 2.5"
  spec.add_dependency "kramdown-parser-gfm", "~> 1.1"
  spec.add_dependency "listen", "~> 3.10"
  spec.add_dependency "protocol-url", "~> 0.4"
  spec.add_dependency "rmagick", "~> 7.0"
  spec.add_dependency "samovar", "~> 2.5"
  spec.add_dependency "syntax_tree", "~> 6.3"
  spec.add_dependency "syntax_tree-haml", "~> 4.0"
  spec.add_dependency "toml-rb", "~> 4.2"
  spec.add_dependency "tsort", "~> 0.2.0"
end
