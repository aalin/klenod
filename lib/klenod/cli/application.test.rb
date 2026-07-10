# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"

require_relative "../runtime"
require_relative "application"

class Klenod::CLI::Application::Test < Minitest::Test
  def test_build_command_writes_runtime_bundle
    Dir.mktmpdir do |dir|
      source_dir = "#{dir}/src"
      output = "#{dir}/dist/klenod.bundle"
      FileUtils.mkdir_p(source_dir)
      File.write("#{source_dir}/entry.rb", "VALUE = 42\n")

      stdout = StringIO.new
      command =
        Klenod::CLI::Application.new(
          [
            "build",
            "--source", source_dir,
            "--entry", "entry",
            "--output", output
          ],
          output: stdout
        )
      bundle = command.call
      loaded = Klenod::Runtime.load_bundle(output)

      assert_equal(42, loaded.exports("entry")::VALUE)
      assert_equal(["entry"], bundle.entrypoints.keys)
      assert_includes(stdout.string, "Built #{output}")
      assert_includes(stdout.string, "Source root: #{source_dir}")
    end
  end

  def test_version_option_prints_version
    stdout = StringIO.new
    command = Klenod::CLI::Application.new(["--version"], output: stdout)

    command.call

    assert_equal("#{Klenod::VERSION}\n", stdout.string)
  end
end
