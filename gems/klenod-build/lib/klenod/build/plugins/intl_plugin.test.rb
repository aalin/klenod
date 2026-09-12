# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/runtime"
require_relative "../context"

class Klenod::Build::Plugins::IntlPlugin::Test < Minitest::Test
  def test_translations_are_cached_until_the_companion_changes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.intl.en.toml", "title = \"Hello\"\n")
      plugin = Klenod::Build::Plugins::IntlPlugin.new
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin]).graph
      module_id = Klenod::Build::ModuleId.new("pages/page.haml", nil)

      first = plugin.translations_for(context, module_id)

      assert_equal({"en" => {"title" => "Hello"}}, first)
      assert_same(first.fetch("en"), plugin.translations_for(context, module_id).fetch("en"), "unchanged companions are served from the cache")

      File.write("#{dir}/pages/page.intl.en.toml", "title = \"Hello again\"\n")
      changed = plugin.translations_for(context, module_id)

      assert_equal({"en" => {"title" => "Hello again"}}, changed)
      refute_same(first.fetch("en"), changed.fetch("en"))
    end
  end

  def test_invalidation_evicts_changed_and_removed_companions
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      path = "#{dir}/pages/page.intl.en.toml"
      File.write(path, "title = \"Hello\"\n")
      plugin = Klenod::Build::Plugins::IntlPlugin.new
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin]).graph
      module_id = Klenod::Build::ModuleId.new("pages/page.haml", nil)
      first = plugin.translations_for(context, module_id)

      assert_equal([], plugin.invalidate_module_ids([path], context))
      refute_same(first.fetch("en"), plugin.translations_for(context, module_id).fetch("en"))

      File.delete(path)
      plugin.invalidate_module_ids([path], context)

      assert_equal({}, plugin.translations_for(context, module_id))
    end
  end

  def test_parse_errors_are_not_cached
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.intl.en.toml", "title = \"unterminated\n")
      plugin = Klenod::Build::Plugins::IntlPlugin.new
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin]).graph
      module_id = Klenod::Build::ModuleId.new("pages/page.haml", nil)

      assert_raises(Klenod::Build::Plugins::IntlPlugin::ParseError) { plugin.translations_for(context, module_id) }

      File.write("#{dir}/pages/page.intl.en.toml", "title = \"Fixed\"\n")

      assert_equal({"en" => {"title" => "Fixed"}}, plugin.translations_for(context, module_id))
    end
  end
end
