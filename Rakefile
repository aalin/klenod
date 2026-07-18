# frozen_string_literal: true

require "minitest/test_task"
require "rbconfig"

ENV["RUBOCOP_CACHE_ROOT"] ||= File.expand_path("tmp/rubocop_cache", __dir__)

KLENOD_VERSION = File.expand_path("KLENOD_VERSION", __dir__)
VERSION_FILES = {
  "gems/klenod/lib/klenod/version.rb" => ["Klenod", "VERSION"],
  "gems/klenod-build/lib/klenod/build/version.rb" => ["Klenod", "Build", "VERSION"],
  "gems/klenod-runtime/lib/klenod/runtime/version.rb" => ["Klenod", "Runtime", "VERSION"],
  "gems/klenod-rack/lib/klenod/rack/version.rb" => ["Klenod", "Rack", "VERSION"]
}.freeze

TEST_LIBS = [
  "gems/klenod/lib",
  "gems/klenod-runtime/lib",
  "gems/klenod-build/lib",
  "gems/klenod-rack/lib"
].freeze
GEMS = {
  "klenod-runtime" => "gems/klenod-runtime",
  "klenod-build" => "gems/klenod-build",
  "klenod-rack" => "gems/klenod-rack",
  "klenod" => "gems/klenod"
}.freeze

def minitest_task(name, description, globs)
  Minitest::TestTask.create(name) do |test|
    test.libs.concat(TEST_LIBS)
    test.test_globs = globs
  end
  Rake::Task[name].clear_comments
  Rake::Task[name].comment = description
end

def with_unbundled_env(&)
  if defined?(Bundler)
    Bundler.with_unbundled_env(&)
  else
    yield
  end
end

def bundle_command
  [RbConfig.ruby, "-S", "bundle"]
end

def root_version
  File.read(KLENOD_VERSION).strip
end

def gem_command
  [RbConfig.ruby, "-S", "gem"]
end

def version_file_source(namespace, version)
  modules = namespace[0...-1]
  constant = namespace.last
  indent = +""
  lines = ["# frozen_string_literal: true", ""]

  modules.each do |name|
    lines << "#{indent}module #{name}"
    indent << "  "
  end

  lines << "#{indent}#{constant} = #{version.inspect}"

  modules.reverse_each do
    indent = indent[0...-2]
    lines << "#{indent}end"
  end

  "#{lines.join("\n")}\n"
end

namespace :test do
  minitest_task(:runtime, "Run klenod-runtime tests", ["gems/klenod-runtime/lib/**/*.test.rb"])
  minitest_task(:build, "Run klenod-build tests", ["gems/klenod-build/lib/**/*.test.rb"])
  minitest_task(:rack, "Run klenod-rack tests", ["gems/klenod-rack/lib/**/*.test.rb"])
  minitest_task(:meta, "Run klenod meta gem tests", ["gems/klenod/lib/**/*.test.rb"])
  minitest_task(:standalone, "Run standalone example tests", ["example/standalone/**/*.test.rb"])
  minitest_task(:box, "Run Ruby::Box example tests", ["example/box/**/*.test.rb"])
  minitest_task(:performance, "Run performance example tests", ["example/performance/**/*.test.rb"])

  desc "Run web example tests with the example/web bundle"
  task :web do
    with_unbundled_env do
      Dir.chdir("example/web") do
        sh(*bundle_command, "check")
        sh(*bundle_command, "exec", "ruby", "example.test.rb")
      end
    end
  end

  desc "Run all packaged gem tests"
  task gems: %i[runtime build rack meta]

  desc "Run all example app tests"
  task examples: %i[standalone box performance web]
end

namespace :version do
  desc "Update generated gem version constants from KLENOD_VERSION"
  task :sync do
    version = root_version

    VERSION_FILES.each do |path, namespace|
      File.write(path, version_file_source(namespace, version))
    end
  end

  desc "Verify generated gem version constants match KLENOD_VERSION"
  task :check do
    version = root_version
    mismatches =
      VERSION_FILES.filter_map do |path, namespace|
        expected = version_file_source(namespace, version)
        [path, namespace.join("::")] unless File.read(path) == expected
      end

    next if mismatches.empty?

    mismatches.each do |path, constant|
      warn "#{path} does not match #{constant} = #{version.inspect}"
    end
    abort "Run `bundle exec rake version:sync`."
  end
end

require "standard/rake"

desc "Build all gem packages into pkg/"
task build: "version:check" do
  version = root_version
  FileUtils.mkdir_p("pkg")

  GEMS.each do |name, dir|
    Dir.chdir(dir) do
      sh(*gem_command, "build", "#{name}.gemspec", "--output", "../../pkg/#{name}-#{version}.gem")
    end
  end
end

desc "Run all gem and example tests"
task test: ["version:check", "test:gems", "test:examples"]
task default: %i[test standard]
