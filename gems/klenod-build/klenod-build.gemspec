# frozen_string_literal: true

root = File.expand_path(__dir__)
require File.expand_path("../klenod-runtime/lib/klenod/version", __dir__)

Gem::Specification.new do |spec|
  spec.name = "klenod-build"
  spec.version = Klenod::VERSION
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Build graph and plugins for Klenod."
  spec.description = "Klenod build constructs Ruby module graphs, runs plugins, emits assets, and serializes runtime bundles."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod"

  spec.files =
    Dir.chdir(root) do
      [
        "README.md",
        "lib/klenod/build.rb",
        "lib/klenod/build/cli.rb",
        "lib/klenod/build/watcher.rb",
        *Dir["lib/klenod/build/**/*.rb"]
      ].select { |path| File.file?(path) && !path.end_with?(".test.rb") }
    end
  spec.require_paths = ["lib"]

  spec.add_dependency "klenod-runtime", "= #{Klenod::VERSION}"
  spec.add_dependency "async", "~> 2.42"
  spec.add_dependency "async-http", "~> 0.95.1"
  spec.add_dependency "image_size", "~> 3.6"
  spec.add_dependency "listen", "~> 3.10"
  spec.add_dependency "mayu-css", "~> 0.1.5"
  spec.add_dependency "rmagick", "~> 7.0"
  spec.add_dependency "samovar", "~> 2.5"
  spec.add_dependency "syntax_tree", "~> 6.3"
  spec.add_dependency "syntax_tree-haml", "~> 4.0"
  spec.add_dependency "toml-rb", "~> 4.2"
  spec.add_dependency "tsort", "~> 0.2.0"
end
