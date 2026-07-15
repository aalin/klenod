# frozen_string_literal: true

require "minitest/test_task"

ENV["RUBOCOP_CACHE_ROOT"] ||= File.expand_path("tmp/rubocop_cache", __dir__)

TEST_LIBS = [
  "gems/klenod/lib",
  "gems/klenod-runtime/lib",
  "gems/klenod-build/lib",
  "gems/klenod-rack/lib"
].freeze

def minitest_task(name, globs)
  Minitest::TestTask.create(name) do |test|
    test.libs.concat(TEST_LIBS)
    test.test_globs = globs
  end
end

minitest_task(:test, ["gems/*/lib/**/*.test.rb", "example/**/*.test.rb"])

namespace :test do
  minitest_task(:runtime, ["gems/klenod-runtime/lib/**/*.test.rb"])
  minitest_task(:build, ["gems/klenod-build/lib/**/*.test.rb"])
  minitest_task(:rack, ["gems/klenod-rack/lib/**/*.test.rb"])
  minitest_task(:meta, ["gems/klenod/lib/**/*.test.rb"])
  minitest_task(:examples, ["example/**/*.test.rb"])

  task gems: %i[runtime build rack meta]
end

require "standard/rake"

task default: %i[test standard]
