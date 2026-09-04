# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

require "klenod/build/context"
require "klenod/build/plugins/ruby_plugin"
require "klenod/build/watcher"

require_relative "plugin"
require_relative "suite"

class Klenod::Test::PluginTest < Minitest::Test
  Plugin = Klenod::Test::Plugin
  Suite = Klenod::Test::Suite
  UpdateEvent = Klenod::Build::UpdateEvent

  def test_discovers_test_files_in_stable_order
    with_files(
      "z.test.rb" => "def test_z; end\n",
      "components/a.test.rb" => "def test_a; end\n",
      "components/a.rb" => "VALUE = 1\n"
    ) do |dir|
      plugin = Plugin.new

      assert_equal(
        ["app:/components/a.test.rb", "app:/z.test.rb"],
        plugin.discover(source_dir: dir).map(&:to_s)
      )
    end
  end

  def test_test_entries_can_import_application_modules
    with_files(
      "value.rb" => "VALUE = 42\n",
      "value.test.rb" => <<~RUBY
        Value = import("./value")

        def test_value
          Value::VALUE
        end
      RUBY
    ) do |dir|
      context, = test_context(dir)
      exports = context.entry("value.test.rb").exports
      test_instance = Object.new.extend(exports)

      assert_equal(42, test_instance.test_value)
    end
  end

  def test_application_modules_cannot_import_test_files
    ["./value.test.rb", "./value.test", "./value.test.rb"].each_with_index do |specifier, index|
      import_method = (index == 2) ? "lazy_import" : "import"
      with_files(
        "value.test.rb" => "def test_value; end\n",
        "entry.rb" => "TestFile = #{import_method}(#{specifier.inspect})\n"
      ) do |dir|
        context, = test_context(dir)

        error = assert_raises(Klenod::Test::ImportError) { context.collect("entry.rb") }
        assert_includes(error.message, "Test file \"value.test.rb\" cannot be imported")
      end
    end
  end

  def test_test_files_cannot_import_other_test_files
    with_files(
      "one.test.rb" => "Other = import(\"./two.test.rb\")\n",
      "two.test.rb" => "def test_two; end\n"
    ) do |dir|
      context, = test_context(dir)

      assert_raises(Klenod::Test::ImportError) { context.collect("one.test.rb") }
    end
  end

  def test_collect_indexes_dependencies_without_evaluating_modules
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "evaluated")
      write_files(
        dir,
        "value.rb" => "File.write(#{marker.inspect}, \"evaluated\")\n",
        "value.test.rb" => "Value = import(\"./value\")\n"
      )
      context, plugin = test_context(dir)

      selection = Suite.new(context: context, plugin: plugin).collect

      assert_equal(["value.test.rb"], selection.test_paths)
      refute_path_exists(marker)
    end
  end

  def test_update_selects_tests_with_direct_transitive_and_shared_dependencies
    with_files(
      "shared.rb" => "VALUE = 1\n",
      "intermediate.rb" => "Shared = import(\"./shared\")\n",
      "other.rb" => "VALUE = 2\n",
      "a.test.rb" => "Intermediate = import(\"./intermediate\")\n",
      "b.test.rb" => "Shared = import(\"./shared\")\n",
      "other.test.rb" => "Other = import(\"./other\")\n"
    ) do |dir|
      context, plugin = test_context(dir)
      suite = Suite.new(context: context, plugin: plugin)
      suite.collect
      shared_path = File.join(dir, "shared.rb")
      File.write(shared_path, "VALUE = 3\n")

      selection = suite.update(update_event(context, changed_paths: [shared_path]))

      assert_equal(["a.test.rb", "b.test.rb"], selection.test_paths)
      assert_empty(selection.removed_test_paths)
    end
  end

  def test_update_tracks_lazy_dependencies
    with_files(
      "lazy.rb" => "VALUE = 1\n",
      "lazy.test.rb" => "LazyValue = lazy_import(\"./lazy\")\n"
    ) do |dir|
      context, plugin = test_context(dir)
      suite = Suite.new(context: context, plugin: plugin)
      suite.collect
      lazy_path = File.join(dir, "lazy.rb")
      File.write(lazy_path, "VALUE = 2\n")

      selection = suite.update(update_event(context, changed_paths: [lazy_path]))

      assert_equal(["lazy.test.rb"], selection.test_paths)
    end
  end

  def test_update_discovers_added_tests_and_removes_deleted_tests
    with_files("one.test.rb" => "def test_one; end\n") do |dir|
      context, plugin = test_context(dir)
      suite = Suite.new(context: context, plugin: plugin)
      suite.collect
      added_path = File.join(dir, "two.test.rb")
      File.write(added_path, "def test_two; end\n")

      added = suite.update(update_event(context, changed_paths: [added_path]))
      File.delete(File.join(dir, "one.test.rb"))
      removed = suite.update(update_event(context, removed_paths: [File.join(dir, "one.test.rb")]))

      assert_equal(["two.test.rb"], added.test_paths)
      assert_empty(added.removed_test_paths)
      assert_empty(removed.test_paths)
      assert_equal(["one.test.rb"], removed.removed_test_paths)
    end
  end

  def test_update_retries_tests_whose_graph_failed_to_collect
    with_files("broken.test.rb" => "Missing = import(\"./missing\")\n") do |dir|
      context, plugin = test_context(dir)
      suite = Suite.new(context: context, plugin: plugin)

      assert_equal(["broken.test.rb"], suite.collect.test_paths)

      unrelated_path = File.join(dir, "unrelated.rb")
      File.write(unrelated_path, "VALUE = 1\n")
      selection = suite.update(update_event(context, changed_paths: [unrelated_path]))

      assert_equal(["broken.test.rb"], selection.test_paths)
    end
  end

  def test_update_selects_tests_when_a_haml_companion_changes
    with_files(
      "Card.haml" => "%strong Card\n",
      "Card.test.rb" => "Card = import(\"./Card.haml\")\n"
    ) do |dir|
      plugin = Plugin.new
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin, *Klenod::Build::Context.default_plugins])
      suite = Suite.new(context: context, plugin: plugin)
      suite.collect
      intl_path = File.join(dir, "Card.intl.en.toml")
      File.write(intl_path, "title = \"Card\"\n")

      selection = suite.update(update_event(context, changed_paths: [intl_path]))

      assert_equal(["Card.test.rb"], selection.test_paths)
    end
  end

  def test_normal_bundles_do_not_include_discovered_tests
    with_files(
      "entry.rb" => "VALUE = 1\n",
      "entry.test.rb" => "Entry = import(\"./entry\")\n"
    ) do |dir|
      context, = test_context(dir)
      bundle = context.graph.bundle(entrypoints: ["entry.rb"])

      assert_equal(["app:/entry.rb"], bundle.modules.keys)
    end
  end

  private

  def test_context(dir)
    plugin = Plugin.new
    context = Klenod::Build::Context.new(
      source_dir: dir,
      plugins: [plugin, Klenod::Build::Plugins::RubyPlugin.new]
    )
    [context, plugin]
  end

  def update_event(context, changed_paths: [], removed_paths: [])
    result = context.invalidate_paths(changed_paths, removed_paths: removed_paths)
    UpdateEvent.new(changed_paths.freeze, removed_paths.freeze, 1, result)
  end

  def with_files(files)
    Dir.mktmpdir do |dir|
      write_files(dir, files)
      yield dir
    end
  end

  def write_files(dir, files)
    files.each do |path, source|
      full_path = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, source)
    end
  end
end
