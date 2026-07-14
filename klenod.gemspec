# frozen_string_literal: true

require_relative "lib/klenod/version"

Gem::Specification.new do |spec|
  spec.name = "klenod"
  spec.version = Klenod::VERSION
  spec.authors = ["Andrés Alin"]
  spec.email = ["andreas.alin@gmail.com"]

  spec.summary = "Experimental Ruby module bundler."
  spec.description = "Klenod builds Ruby module graphs with plugins for web-style assets, transforms, routing, and runtime bundles."
  spec.homepage = "https://github.com/aalin/klenod"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aalin/klenod"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .standard.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "async", "~> 2.42"
  spec.add_dependency "async-http", "~> 0.95.1"
  spec.add_dependency "image_size", "~> 3.6"
  spec.add_dependency "listen", "~> 3.10"
  spec.add_dependency "mayu-css", "~> 0.1.5"
  spec.add_dependency "rbnacl", "~> 7.1"
  spec.add_dependency "rmagick", "~> 7.0"
  spec.add_dependency "samovar", "~> 2.5"
  spec.add_dependency "syntax_tree", "~> 6.3"
  spec.add_dependency "syntax_tree-haml", "~> 4.0"
  spec.add_dependency "toml-rb", "~> 4.2"
  spec.add_dependency "tsort", "~> 0.2.0"

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "standard", "~> 1.3"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
