# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"

require "klenod/build"
require "klenod/runtime/source_map"

require_relative "coverage"
require_relative "plugin"

class Klenod::Test::CoverageResult::Test < Minitest::Test
  Mod = Data.define(:eval_path, :source_map)
  Graph = Data.define(:mods)
  Context = Data.define(:graph)

  def test_keeps_ruby_and_maps_generated_source_lines
    Dir.mktmpdir do |directory|
      ruby_path = write(directory, "value.rb", "VALUE = 1\n")
      haml_source = "%p First\n%p Second\n"
      haml_path = write(directory, "Card.haml", haml_source)
      data_path = write(directory, "value.json", "{}\n")
      test_path = write(directory, "value.test.rb", "VALUE = 1\n")
      source_map = Klenod::Runtime::SourceMap::SourceMap.parse(
        haml_source,
        "# SourceMapMark:1\nfirst\n# SourceMapMark:2\nsecond\n"
      )
      mods = {
        module_id("value.rb") => Mod.new(ruby_path, nil),
        module_id("Card.haml") => Mod.new(haml_path, source_map),
        module_id("value.json") => Mod.new(data_path, nil),
        module_id("value.test.rb") => Mod.new(test_path, nil)
      }
      files = Covered::Files.new
      files.add(coverage(ruby_path, [nil, 2]))
      files.add(coverage(haml_path, [nil, nil, 3, nil, 0]))
      files.add(coverage(data_path, [nil, 1]))
      files.add(coverage(test_path, [nil, 1]))

      result = Klenod::Test::CoverageResult.new(
        files,
        context: Context.new(Graph.new(mods)),
        plugin: Klenod::Test::Plugin.new
      ).each.to_a

      assert_equal([ruby_path, haml_path], result.map(&:path))
      assert_equal([nil, 2], result.fetch(0).counts)
      assert_equal([nil, 3, 0], result.fetch(1).counts)
    end
  end

  def test_combines_generated_lines_mapped_to_the_same_source_line
    Dir.mktmpdir do |directory|
      source = "%p Hello\n"
      path = write(directory, "Card.haml", source)
      source_map = Klenod::Runtime::SourceMap::SourceMap.parse(
        source,
        "# SourceMapMark:1\nfirst\nsecond\n"
      )
      files = Covered::Files.new
      files.add(coverage(path, [nil, nil, 2, 3]))

      result = Klenod::Test::CoverageResult.new(
        files,
        context: Context.new(Graph.new({module_id("Card.haml") => Mod.new(path, source_map)})),
        plugin: Klenod::Test::Plugin.new
      ).each.to_a.fetch(0)

      assert_equal([nil, 3], result.counts)
    end
  end

  def test_omits_generated_source_without_mapped_executable_lines
    Dir.mktmpdir do |directory|
      source = "%p Hello\n"
      path = write(directory, "Card.haml", source)
      source_map = Klenod::Runtime::SourceMap::SourceMap.parse(source, "generated\n")
      files = Covered::Files.new
      files.add(coverage(path, [nil, 1]))

      result = Klenod::Test::CoverageResult.new(
        files,
        context: Context.new(Graph.new({module_id("Card.haml") => Mod.new(path, source_map)})),
        plugin: Klenod::Test::Plugin.new
      ).each.to_a

      assert_empty(result)
    end
  end

  private

  def module_id(path)
    Klenod::Build::ModuleId.new(path, nil)
  end

  def coverage(path, counts)
    Covered::Coverage.new(Covered::Source.for(path), counts)
  end

  def write(directory, path, source)
    full_path = File.join(directory, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, source)
    full_path
  end
end

class Klenod::Test::CoverageRunner::Test < Minitest::Test
  def test_reports_application_coverage
    with_context("value.rb" => "VALUE = 1\n") do |context, plugin|
      output = StringIO.new
      runner = coverage_runner(context, plugin, output:)

      status = runner.call do
        context.entry("value.rb").exports
        0
      end

      assert_equal(0, status)
      assert_includes(output.string, "1 files checked")
      assert_includes(output.string, "100.0% covered")
    end
  end

  def test_fails_when_overall_coverage_is_below_the_minimum
    source = <<~RUBY
      def covered
        1
      end

      def missed
        2
      end
    RUBY

    with_context("value.rb" => source) do |context, plugin|
      output = StringIO.new
      runner = coverage_runner(context, plugin, output:, report: :quiet, minimum: 100)

      status = runner.call do
        exports = context.entry("value.rb").exports
        Object.new.extend(exports).covered
        0
      end

      assert_equal(1, status)
      assert_includes(output.string, "less than required minimum of 100.0%")
    end
  end

  def test_preserves_a_test_failure_status_when_coverage_is_below_the_minimum
    with_context("value.rb" => "def missed\n  1\nend\n") do |context, plugin|
      output = StringIO.new
      runner = coverage_runner(context, plugin, output:, report: :quiet, minimum: 100)

      status = runner.call do
        context.entry("value.rb").exports
        7
      end

      assert_equal(7, status)
      assert_includes(output.string, "less than required minimum")
    end
  end

  private

  def coverage_runner(context, plugin, output:, report: :brief, minimum: nil)
    Klenod::Test::CoverageRunner.new(
      context:,
      plugin:,
      config: Klenod::Test::CoverageConfig.build(report:, minimum:),
      output:
    )
  end

  def with_context(files)
    Dir.mktmpdir do |directory|
      files.each { |path, source| File.write(File.join(directory, path), source) }
      plugin = Klenod::Test::Plugin.new
      context = Klenod::Build::Context.new(
        source_dir: directory,
        plugins: [plugin, Klenod::Build::Plugins::RubyPlugin.new]
      )
      yield context, plugin
    end
  end
end
