# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

require_relative "config"

class Klenod::Test::ConfigLoader::Test < Minitest::Test
  def test_finds_config_from_a_nested_directory
    Dir.mktmpdir do |directory|
      nested = File.join(directory, "src", "components")
      FileUtils.mkdir_p(nested)
      File.write(File.join(directory, "klenod.test.rb"), config_source)

      assert_equal(
        File.join(directory, "klenod.test.rb"),
        Klenod::Test::ConfigLoader.find(nested)
      )
    end
  end

  def test_loads_callbacks_and_base_directory
    Dir.mktmpdir do |directory|
      path = File.join(directory, "klenod.test.rb")
      File.write(path, config_source)

      config = Klenod::Test::ConfigLoader.load(path)

      assert_equal(directory, config.base_dir)
      assert_equal(:context, config.context.call)
      assert_equal(3, config.execute.call(:context, ["example.test.rb"]))
      assert_equal("context: broken", config.format_error.call(RuntimeError.new("broken"), :context))
      assert_equal(:brief, config.coverage.report)
      assert_nil(config.coverage.minimum)
    end
  end

  def test_loads_coverage_settings
    with_config(<<~RUBY) do |config|
      context { :context }
      execute { 0 }
      coverage report: :partial, minimum: 87.5
    RUBY
      assert_equal(:partial, config.coverage.report)
      assert_equal(87.5, config.coverage.minimum)
    end
  end

  def test_rejects_invalid_coverage_settings
    error = assert_raises(Klenod::Test::ConfigError) do
      Klenod::Test::CoverageConfig.build(report: :unknown)
    end
    assert_includes(error.message, "Unknown coverage report")

    error = assert_raises(Klenod::Test::ConfigError) do
      Klenod::Test::CoverageConfig.build(minimum: 101)
    end
    assert_includes(error.message, "between 0 and 100")

    error = assert_raises(Klenod::Test::ConfigError) do
      Klenod::Test::CoverageConfig.build(minimum: "high")
    end
    assert_includes(error.message, "must be a number")
  end

  def test_requires_context_and_execute_callbacks
    Dir.mktmpdir do |directory|
      path = File.join(directory, "klenod.test.rb")
      File.write(path, "# empty\n")

      error = assert_raises(ArgumentError) { Klenod::Test::ConfigLoader.load(path) }

      assert_includes(error.message, path)
      assert_includes(error.message, "missing context and execute")
    end
  end

  private

  def with_config(source)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "klenod.test.rb")
      File.write(path, source)
      yield Klenod::Test::ConfigLoader.load(path)
    end
  end

  def config_source
    <<~RUBY
      context { :context }
      execute { |_context, paths| paths.length + 2 }
      format_error { |error, context| "\#{context}: \#{error.message}" }
    RUBY
  end
end
