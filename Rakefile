# frozen_string_literal: true

require "minitest/test_task"

ENV["RUBOCOP_CACHE_ROOT"] ||= File.expand_path("tmp/rubocop_cache", __dir__)

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

require "standard/rake"

task default: %i[test standard]
