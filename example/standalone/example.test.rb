# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

require "bundler/setup"
require "klenod"

class Klenod::StandaloneExampleTest < Minitest::Test
  def test_standalone_example_generates_report
    Dir.mktmpdir do |dir|
      output = "#{dir}/report.txt"
      with_env("REPORT_OUTPUT" => output) do
        context = example_config.context
        entry = context.entry(example_config.entrypoints.fetch(0))

        assert_equal("app:/main.rb", entry.id.to_s)
        refute(File.exist?(output), "Expected entry handle creation to avoid running the report")
        entry.exports
      end

      report = File.binread(output)

      assert_includes(report, "Release Report")
      assert_includes(report, "Version: 0.2.0")
      assert_includes(report, "Completed: 8/11")
      assert_includes(report, "Maintainers: Build, Runtime")
      assert_includes(report, "Notes: Generated from plain text")
    end
  end

  def test_standalone_example_builds_executable_bundle
    Dir.mktmpdir do |dir|
      output = "#{dir}/release_report"
      report_path = "#{dir}/report.txt"
      context = example_config.context

      bundle = context.build_executable(entrypoints: example_config.entrypoints, output: output)
      refute(File.exist?(report_path), "Expected build to avoid running entrypoint side effects")
      stdout, stderr, status =
        with_env("REPORT_OUTPUT" => report_path) do
          Open3.capture3(
            RbConfig.ruby,
            "-I#{File.expand_path("../..", __dir__)}",
            output
          )
        end

      assert(status.success?, "stdout:\n#{stdout}\nstderr:\n#{stderr}")
      assert_equal(["main"], bundle.entrypoints.keys)
      assert_includes(File.binread(report_path), "Release Report")
    end
  end

  def test_report_test_tracks_each_imported_data_file
    %w[tasks.json owners.yaml release.toml notes.txt].each do |name|
      config = example_config
      context = config.context
      plugin = context.graph.plugins.find { it.is_a?(Klenod::Build::Plugins::TestPlugin::Plugin) }
      suite = Klenod::Build::TestSuite.new(context:, plugin:)
      suite.collect
      path = File.join(config.source_path, "data", name)
      result = context.invalidate_paths([path])
      event = Klenod::Build::UpdateEvent.new([path], [], 1, result)

      assert_equal(["report.test.rb"], suite.update(event).test_paths, name)
    end
  end

  private

  def example_config
    Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
  end

  def with_env(values)
    previous = values.to_h { |key, _value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end
