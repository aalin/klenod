# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "application"

class Klenod::CLI::Application::Test < Minitest::Test
  def test_help_lists_build_graph_test_and_coverage_commands
    output = StringIO.new

    Klenod::CLI::Application.new(["--help"], output:).call

    assert_includes(output.string, "One of: build, coverage, graph, test")
    assert_includes(output.string, "Run and watch application tests")
    assert_includes(output.string, "Run the full application test suite with coverage")
  end

  def test_test_command_loads_the_nearest_test_config
    Dir.mktmpdir do |directory|
      source_dir = File.join(directory, "src")
      Dir.mkdir(source_dir)
      File.write(
        File.join(directory, "klenod.test.rb"),
        <<~RUBY
          context do
            Klenod::Build::Context.new(
              source_dir: #{source_dir.inspect},
              plugins: [Klenod::Test::Plugin.new]
            )
          end
          execute { 0 }
        RUBY
      )
      output = StringIO.new

      status = Dir.chdir(source_dir) do
        Klenod::CLI::Application.new(["test", "--run"], output:).call
      end

      assert_equal(0, status)
      assert_includes(output.string, "RUN  0 test files")
    end
  end

  def test_test_command_reports_a_missing_config
    Dir.mktmpdir do |directory|
      output = StringIO.new

      status = Dir.chdir(directory) do
        Klenod::CLI::Application.new(["test", "--run"], output:).call
      end

      assert_equal(1, status)
      assert_equal("Could not find klenod.test.rb\n", output.string)
    end
  end

  def test_test_command_reports_incomplete_config
    Dir.mktmpdir do |directory|
      path = File.join(directory, "klenod.test.rb")
      File.write(path, "context { :context }\n")
      output = StringIO.new

      status = Dir.chdir(directory) do
        Klenod::CLI::Application.new(["test", "--run"], output:).call
      end

      assert_equal(1, status)
      assert_includes(output.string, path)
      assert_includes(output.string, "missing execute")
    end
  end

  def test_coverage_worker_uses_the_nearest_test_config
    Dir.mktmpdir do |directory|
      source_dir = File.join(directory, "src")
      Dir.mkdir(source_dir)
      File.write(
        File.join(directory, "klenod.test.rb"),
        <<~RUBY
          context do
            Klenod::Build::Context.new(
              source_dir: #{source_dir.inspect},
              plugins: [Klenod::Test::Plugin.new]
            )
          end
          execute { |_context, paths| paths.empty? ? 0 : 1 }
          coverage report: :quiet, minimum: 100
        RUBY
      )
      output = StringIO.new

      status = Dir.chdir(source_dir) do
        Klenod::CLI::Application.new(
          ["coverage", "--report", "brief", "--minimum", "0", "--worker", "--"],
          output:
        ).call
      end

      assert_equal(0, status)
      assert_includes(output.string, "0 files checked")
    end
  end

  def test_coverage_command_rejects_invalid_overrides
    Dir.mktmpdir do |directory|
      File.write(
        File.join(directory, "klenod.test.rb"),
        "context { :context }\nexecute { 0 }\n"
      )
      output = StringIO.new

      status = Dir.chdir(directory) do
        Klenod::CLI::Application.new(["coverage", "--minimum", "101"], output:).call
      end

      assert_equal(1, status)
      assert_includes(output.string, "between 0 and 100")
    end
  end

  def test_coverage_command_passes_cli_overrides_to_its_worker
    command = Klenod::Test::CLI::CoverageCommand.new(
      ["--report", "partial", "--minimum", "80"],
      output: StringIO.new
    )

    assert_equal(
      ["coverage", "--report", "partial", "--minimum", "80"],
      command.send(:worker_command).last(5)
    )
  end
end
