# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
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
      File.write(
        "#{dir}/klenod.config.rb",
        <<~RUBY
          source_dir "src"
          entrypoint "entry"
          output "dist/klenod.bundle"
          plugins [
            Klenod::Build::Plugins::RubyPlugin.new
          ]
        RUBY
      )

      stdout = StringIO.new
      bundle = nil
      Dir.chdir(dir) do
        command = Klenod::CLI::Application.new(["build"], output: stdout)
        bundle = command.call
      end
      loaded = Klenod::Runtime.load_bundle(output)

      assert_equal(42, loaded.exports("entry")::VALUE)
      assert_equal(["entry"], bundle.entrypoints.keys)
      assert_includes(stdout.string, "Built ")
      assert_includes(stdout.string, "Source root: ")
    end
  end

  def test_build_command_finds_config_in_parent_directory
    Dir.mktmpdir do |dir|
      source_dir = "#{dir}/app"
      output = "#{dir}/dist/config.bundle"
      nested = "#{source_dir}/pages"
      FileUtils.mkdir_p(nested)
      File.write("#{source_dir}/entry.rb", "VALUE = 42\n")
      File.write(
        "#{dir}/klenod.config.rb",
        <<~RUBY
          source_dir "app"
          entrypoint "entry"
          output "dist/config.bundle"
          plugins [
            Klenod::Build::Plugins::RubyPlugin.new
          ]
        RUBY
      )

      stdout = StringIO.new
      Dir.chdir(nested) do
        command = Klenod::CLI::Application.new(["build"], output: stdout)
        command.call
      end
      loaded = Klenod::Runtime.load_bundle(output)

      assert_equal(42, loaded.exports("entry")::VALUE)
      assert_includes(stdout.string, "Built ")
    end
  end

  def test_build_command_writes_executable_bundle
    Dir.mktmpdir do |dir|
      source_dir = "#{dir}/src"
      output = "#{dir}/dist/app"
      result_path = "#{dir}/result.txt"
      FileUtils.mkdir_p(source_dir)
      File.write("#{source_dir}/entry.rb", "File.binwrite(#{result_path.inspect}, \"ran\")\n")
      File.write(
        "#{dir}/klenod.config.rb",
        <<~RUBY
          source_dir "src"
          entrypoint "entry"
          output "dist/app"
          plugins [
            Klenod::Build::Plugins::RubyPlugin.new
          ]
        RUBY
      )

      stdout = StringIO.new
      bundle = nil
      Dir.chdir(dir) do
        command = Klenod::CLI::Application.new(["build", "--executable"], output: stdout)
        bundle = command.call
      end
      loaded = Klenod::Runtime.load_executable_bundle(output)
      ruby_stdout, ruby_stderr, status =
        Open3.capture3(
          RbConfig.ruby,
          "-I#{File.expand_path("..", __dir__)}",
          output
        )

      assert_equal(["entry"], bundle.entrypoints.keys)
      assert_equal(bundle.modules.keys.sort, loaded.modules.keys.sort)
      assert(status.success?, "stdout:\n#{ruby_stdout}\nstderr:\n#{ruby_stderr}")
      assert_equal("ran", File.binread(result_path))
      assert_includes(stdout.string, "Built executable bundle ")
      assert(File.executable?(output), "Expected #{output} to be executable")
    end
  end

  def test_version_option_prints_version
    stdout = StringIO.new
    command = Klenod::CLI::Application.new(["--version"], output: stdout)

    command.call

    assert_equal("#{Klenod::VERSION}\n", stdout.string)
  end
end
