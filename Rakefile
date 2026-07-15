# frozen_string_literal: true

require "minitest/test_task"

ENV["RUBOCOP_CACHE_ROOT"] ||= File.expand_path("tmp/rubocop_cache", __dir__)

Minitest::TestTask.create do |test|
  test.libs.concat(
    [
      "gems/klenod/lib",
      "gems/klenod-runtime/lib",
      "gems/klenod-build/lib",
      "gems/klenod-rack/lib"
    ]
  )
  test.test_globs = ["gems/*/lib/**/*.test.rb", "example/**/*.test.rb"]
end

require "standard/rake"

task default: %i[test standard]
