# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

ENV["RUBOCOP_CACHE_ROOT"] ||= File.expand_path("tmp/rubocop_cache", __dir__)

Minitest::TestTask.create do |test|
  test.libs << "lib"
  test.test_globs = ["lib/**/*.test.rb"]
end

require "standard/rake"

task default: %i[test standard]
