# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class KlenodBoxExampleTest < Minitest::Test
  def test_box_example_builds_and_loads_two_bundles_in_separate_boxes
    build_stdout, build_stderr, build_status =
      Open3.capture3(
        {
          "BUNDLE_GEMFILE" => File.expand_path("Gemfile", __dir__)
        },
        RbConfig.ruby,
        "-S",
        "bundle",
        "exec",
        "ruby",
        "build.rb",
        chdir: __dir__
      )

    assert(build_status.success?, "stdout:\n#{build_stdout}\nstderr:\n#{build_stderr}")
    assert_includes(build_stdout, "Built ")

    stdout, stderr, status =
      Open3.capture3(
        {
          "RUBY_BOX" => "1",
          "BUNDLE_GEMFILE" => File.expand_path("Gemfile", __dir__),
          "HOME" => ENV.fetch("HOME", nil),
          "PATH" => ENV.fetch("PATH", nil)
        },
        RbConfig.ruby,
        "run.rb",
        chdir: __dir__,
        unsetenv_others: true
      )

    assert(status.success?, "stdout:\n#{stdout}\nstderr:\n#{stderr}")
    assert_includes(stdout, "Alpha from box ")
    assert_includes(stdout, "Beta from box ")
    assert_includes(stdout, "Alpha says hello to Box")
    assert_includes(stdout, "Beta says hello to Box")
    assert_includes(stdout, "Different boxes: true")
    assert_includes(stdout, "Main runtime leaked alpha module: false")
  end
end
