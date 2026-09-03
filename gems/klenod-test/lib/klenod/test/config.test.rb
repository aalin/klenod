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
    end
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

  def config_source
    <<~RUBY
      context { :context }
      execute { |_context, paths| paths.length + 2 }
      format_error { |error, context| "\#{context}: \#{error.message}" }
    RUBY
  end
end
