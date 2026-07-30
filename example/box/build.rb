# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "klenod/build"

EXAMPLE_ROOT = __dir__
DIST_DIR = File.join(EXAMPLE_ROOT, "dist")

def build_bundle(name)
  source_dir = File.join(EXAMPLE_ROOT, "src/#{name}")
  output = File.join(DIST_DIR, "#{name}.bundle")
  context =
    Klenod::Build::Context.new(
      source_dir: source_dir,
      plugins: [Klenod::Build::Plugins::RubyPlugin::Plugin.new],
      mode: :production
    )

  context.build(entrypoints: ["main"], output: output)
  output
end

FileUtils.mkdir_p(DIST_DIR)

puts "Built #{build_bundle("alpha")}"
puts "Built #{build_bundle("beta")}"
