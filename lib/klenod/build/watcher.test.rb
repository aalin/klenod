# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

require_relative "asset"
require_relative "context"
require_relative "invalidation_result"
require_relative "watcher"

class Klenod::Build::Watcher::Test < Minitest::Test
  def test_update_event_carries_invalidation_result
    new_asset =
      Klenod::Build::Asset.new(
        "styles/new.css",
        "new",
        "/assets/new.css",
        nil,
        "body {}",
        "text/css",
        {}
      )
    old_asset =
      Klenod::Build::Asset.new(
        "styles/old.css",
        "old",
        "/assets/old.css",
        nil,
        "body {}",
        "text/css",
        {}
      )
    asset_updates = [
      Klenod::Build::AssetUpdate.new("/assets/new.css", nil, new_asset),
      Klenod::Build::AssetUpdate.new("/assets/old.css", old_asset, nil)
    ]
    result =
      Klenod::Build::InvalidationResult.new(
        [],
        [],
        [],
        [],
        ["/assets/new.css"],
        [],
        ["/assets/old.css"],
        asset_updates,
        []
      )
    event = Klenod::Build::UpdateEvent.new(["a.rb"], ["b.rb"], 1, result)

    assert_equal(["a.rb"], event.changed_paths)
    assert_equal(["b.rb"], event.removed_paths)
    assert_equal(1, event.graph_version)
    assert_same(result, event.result)
    assert_equal(["/assets/new.css"], event.asset_changes.added)
    assert_equal(["/assets/old.css"], event.asset_changes.removed)
    assert_equal(asset_updates, event.asset_updates)
  end

  def test_update_event_reports_added_companion_css_assets
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("pages/page.haml")
      events = []
      context.on_update { |event| events << event }

      File.write(css_path, ".title { color: red; }\n")
      event = emit_update(context, [css_path], [], 1)
      styles = context.graph.mods.fetch(Klenod::Build::ModuleId.new("pages/page.haml", nil)).const_get(:Exports)::Styles
      added_update = event.asset_updates.fetch(0)

      assert_same(event, events.fetch(0))
      assert_equal(["pages/page.haml"], event.result.reloaded_module_ids.map(&:to_s))
      assert_equal([], event.result.removed_module_ids)
      assert_equal(event.asset_changes.added, event.asset_updates.map(&:output_path))
      assert(added_update.added?)
      assert_equal("text/css", added_update.current_asset.content_type)
      assert_match(/title/, styles.fetch(:title))
    end
  end

  def test_update_event_reports_removed_companion_css_assets
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(css_path, ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("pages/page.haml")
      old_asset = context.assets_for("pages/page.css").fetch(0)

      File.delete(css_path)
      event = emit_update(context, [], [css_path], 1)
      styles = context.graph.mods.fetch(Klenod::Build::ModuleId.new("pages/page.haml", nil)).const_get(:Exports)::Styles
      removed_update = event.asset_updates.fetch(0)

      assert_equal(["pages/page.css"], event.result.removed_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], event.result.reloaded_module_ids.map(&:to_s))
      assert_equal([old_asset.output_path], event.asset_changes.removed)
      assert(removed_update.removed?)
      assert_equal(old_asset, removed_update.previous_asset)
      assert_nil(removed_update.current_asset)
      assert_equal({}, styles)
    end
  end

  def test_update_event_reports_companion_intl_reload_without_asset_changes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hello\"\n")
      add_event = emit_update(context, [intl_path], [], 1)
      translations =
        context
          .graph
          .mods
          .fetch(Klenod::Build::ModuleId.new("pages/page.haml", nil))
          .const_get(:Exports)::Translations

      File.delete(intl_path)
      remove_event = emit_update(context, [], [intl_path], 2)

      assert_equal(["pages/page.haml"], add_event.result.reloaded_module_ids.map(&:to_s))
      assert(add_event.asset_changes.empty?)
      assert_equal([], add_event.asset_updates)
      assert_equal("Hello", translations.fetch("en-US").fetch("title"))
      assert_equal(["pages/page.haml"], remove_event.result.reloaded_module_ids.map(&:to_s))
      assert(remove_event.asset_changes.empty?)
      assert_equal([], remove_event.asset_updates)
    end
  end

  private

  def emit_update(context, changed_paths, removed_paths, graph_version)
    result = context.invalidate_paths(changed_paths, removed_paths: removed_paths)
    event = Klenod::Build::UpdateEvent.new(changed_paths.freeze, removed_paths.freeze, graph_version, result)

    context.emit_update(event)
    event
  end
end
