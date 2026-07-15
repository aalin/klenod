# frozen_string_literal: true

require "minitest/test_task"

ENV["RUBOCOP_CACHE_ROOT"] ||= File.expand_path("tmp/rubocop_cache", __dir__)

ROOT_VERSION = File.expand_path("VERSION", __dir__)
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

def minitest_task(name, description, globs)
  Minitest::TestTask.create(name) do |test|
    test.libs.concat(TEST_LIBS)
    test.test_globs = globs
  end
  Rake::Task[name].clear_comments
  Rake::Task[name].comment = description
end

def root_version
  File.read(ROOT_VERSION).strip
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

minitest_task(:test, "Run all gem and example tests", ["gems/*/lib/**/*.test.rb", "example/**/*.test.rb"])

namespace :test do
  minitest_task(:runtime, "Run klenod-runtime tests", ["gems/klenod-runtime/lib/**/*.test.rb"])
  minitest_task(:build, "Run klenod-build tests", ["gems/klenod-build/lib/**/*.test.rb"])
  minitest_task(:rack, "Run klenod-rack tests", ["gems/klenod-rack/lib/**/*.test.rb"])
  minitest_task(:meta, "Run klenod meta gem tests", ["gems/klenod/lib/**/*.test.rb"])
  minitest_task(:examples, "Run example app tests", ["example/**/*.test.rb"])

  desc "Run all packaged gem tests"
  task gems: %i[runtime build rack meta]
end

namespace :version do
  desc "Update generated gem version constants from VERSION"
  task :sync do
    version = root_version

    VERSION_FILES.each do |path, namespace|
      File.write(path, version_file_source(namespace, version))
    end
  end

  desc "Verify generated gem version constants match VERSION"
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

task test: ["version:check"]
task default: %i[test standard]
