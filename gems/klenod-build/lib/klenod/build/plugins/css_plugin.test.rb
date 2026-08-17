# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require "klenod/runtime"
require_relative "image_plugin"

class Klenod::Build::Plugins::CssPlugin::Test < Minitest::Test
  def test_ruby_import_of_css_returns_class_map_and_emits_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write("#{dir}/pages/home.rb", "Styles = import(\"../styles/home.css\")\nTITLE = Styles.fetch(:title)\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("pages/home")
      mod = context.graph.mods.fetch(record.id)
      css_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/home.css", nil))

      assert_match(/title/, mod.const_get(:Exports)::TITLE)
      css_asset = css_record.assets.find { |asset| asset.metadata[:type] == :css }

      assert_match(%r{\A/assets/styles_home_css\.[a-f0-9]{16}\.css\z}, css_asset.output_path)
      assert_includes(css_asset.bytes, "color: red")
    end
  end

  def test_css_source_is_read_as_utf_8
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title::before { content: \"🌗\"; }\n", encoding: "UTF-8")
      File.write("#{dir}/pages/home.rb", "Styles = import(\"../styles/home.css\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("pages/home")
      css_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/home.css", nil))
      css_asset = css_record.assets.find { it.metadata[:type] == :css }

      assert_includes(css_asset.bytes, "🌗")
    end
  end

  def test_css_uses_mayu_stylesheet_for_javascript_imports
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\nimg { display: block; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("styles/home.css")
      css_asset = record.assets.find { it.metadata[:type] == :css }

      assert_equal(css_asset.output_path, record.metadata.fetch(:css_javascript_stylesheet_path))
      assert_includes(css_asset.bytes, "sourceMappingURL")
    end
  end

  def test_ruby_import_of_css_returns_element_selector_map
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "img { width: 100%; }\n.title { color: red; }\n")
      File.write(
        "#{dir}/pages/home.rb",
        <<~RUBY
          Styles = import("../styles/home.css")
          IMAGE = Styles.fetch(:__img)
          TITLE = Styles.fetch(:title)
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("pages/home")
      mod = context.graph.mods.fetch(record.id)
      css_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/home.css", nil))
      asset = css_record.assets.fetch(0)

      assert_match(/img/, mod.const_get(:Exports)::IMAGE)
      assert_match(/title/, mod.const_get(:Exports)::TITLE)
      assert_match(/img/, asset.metadata.fetch(:classes).fetch(:__img))
      assert_includes(asset.bytes, "width: 100%")
    end
  end

  def test_css_import_returns_styles_object_with_class_name_helper
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".button { color: red; }\n.enabled { color: green; }\n")
      File.write(
        "#{dir}/pages/home.rb",
        <<~RUBY
          Styles = import("../styles/home.css")
          MISSING = Styles[:missing]
          BUTTON = Styles[:button]
          CLASSES = Styles.class_name(:button, "literal extra", {enabled: true, hidden: false, "plain" => true, missing: true})
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("pages/home")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_nil(exports::MISSING)
      assert_match(/button/, exports::BUTTON)
      assert_includes(exports::CLASSES, exports::BUTTON)
      assert_includes(exports::CLASSES, "literal")
      assert_includes(exports::CLASSES, "extra")
      assert_includes(exports::CLASSES, "plain")
      assert_match(/enabled/, exports::CLASSES)
      refute_includes(exports::CLASSES, "hidden")
      refute_includes(exports::CLASSES, "missing")
    end
  end

  def test_css_dependencies_remove_local_imports_and_replace_url_placeholders
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/styles/base.css", ".base { color: blue; }\n")
      File.binwrite("#{dir}/images/logo.png", "not really a png")
      File.write(
        "#{dir}/styles/home.css",
        <<~CSS
          @import "./base.css";
          .logo { background: url("../images/logo.png"); }
        CSS
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("styles/home.css")
      css = record.assets.first.bytes
      base_javascript_css_path = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/base.css", nil)).metadata.fetch(:css_javascript_stylesheet_path)

      refute_includes(css, "@import")
      refute_includes(css, "/assets/styles_base_css")
      assert_includes(css, "/assets/logo.")
      assert_equal(context.assets_for("styles/base.css").find { it.metadata[:type] == :css }.output_path, base_javascript_css_path)
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("styles/home.css", nil)))
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("styles/base.css", nil)))
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("images/logo.png", nil)))
    end
  end

  def test_css_external_imports_are_preserved
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      font_url = "https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@200..900&display=swap"
      File.write(
        "#{dir}/styles/home.css",
        <<~CSS
          @import url("#{font_url}");

          .title { font-family: "Source Sans 3", sans-serif; }
        CSS
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("styles/home.css")
      css = record.assets.first.bytes

      assert_includes(css, font_url)
      assert_equal(["app:/styles/home.css"], context.graph.records.keys.map(&:to_s).grep_v(/\Avirtual:/))
    end
  end

  def test_css_importing_css_emits_both_assets_in_bundle_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/base.css", ".base { color: blue; }\n")
      File.write("#{dir}/styles/home.css", "@import \"./base.css\";\n.title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["styles/home.css"], output: "#{dir}/bundle.mpk")
      home_asset = context.assets_for("styles/home.css").fetch(0)
      base_asset = context.assets_for("styles/base.css").fetch(0)

      refute_includes(home_asset.bytes, "@import")
      refute_includes(home_asset.bytes, base_asset.output_path)
      assert_match(%r{\A/assets/styles_home_css\.[a-f0-9]{16}\.css\z}, home_asset.output_path)
      assert_match(%r{\A/assets/styles_base_css\.[a-f0-9]{16}\.css\z}, base_asset.output_path)
      assert_equal(4, bundle.assets.length)
    end
  end

  def test_css_importing_ruby_raises_unsupported_file_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/dep.rb", "VALUE = 1\n")
      File.write("#{dir}/styles/home.css", "@import \"./dep.rb\";\n.title { color: red; }\n")

      error = assert_raises(Klenod::Build::UnsupportedFileError) do
        Klenod::Build::Context.new(source_dir: dir).evaluate("styles/home.css")
      end

      assert_match(/CSS @import/, error.message)
      assert_match(/styles\/dep.rb/, error.message)
    end
  end

  def test_css_importing_haml_raises_unsupported_file_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/dep.haml", "%p Hello\n")
      File.write("#{dir}/styles/home.css", "@import \"./dep.haml\";\n.title { color: red; }\n")

      error = assert_raises(Klenod::Build::UnsupportedFileError) do
        Klenod::Build::Context.new(source_dir: dir).evaluate("styles/home.css")
      end

      assert_match(/CSS @import/, error.message)
      assert_match(/styles\/dep.haml/, error.message)
    end
  end

  def test_css_importing_css_refinalizes_parent_when_child_asset_changes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      base_path = "#{dir}/styles/base.css"
      File.write(base_path, ".base { color: blue; }\n")
      File.write("#{dir}/styles/home.css", "@import \"./base.css\";\n.title { color: red; }\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Styles = import("styles/home.css")
          TITLE = Styles.fetch(:title)
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      entry_record = context.evaluate("entry")
      old_home_asset = context.assets_for("styles/home.css").fetch(0)
      old_base_asset = context.assets_for("styles/base.css").fetch(0)

      File.write(base_path, ".base { color: green; }\n")
      result = context.invalidate_paths([base_path])
      new_home_asset = context.assets_for("styles/home.css").fetch(0)
      new_base_asset = context.assets_for("styles/base.css").fetch(0)
      title = context.graph.mods.fetch(entry_record.id).const_get(:Exports)::TITLE

      assert_equal(["app:/styles/base.css"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["app:/styles/home.css", "app:/entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      refute_equal(old_base_asset.output_path, new_base_asset.output_path)
      assert_equal(old_home_asset.output_path, new_home_asset.output_path)
      refute_includes(new_home_asset.bytes, new_base_asset.output_path)
      assert_match(/title/, title)
      assert_includes(result.added_assets, new_base_asset.output_path)
      refute_includes(result.added_assets, new_home_asset.output_path)
      assert_includes(result.removed_assets, old_base_asset.output_path)
      refute_includes(result.removed_assets, old_home_asset.output_path)
    end
  end

  def test_runtime_bundle_preserves_css_import_value_and_asset_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/home.css\")\nTITLE = Styles.fetch(:title)\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      mod = loaded.load("entry")

      assert_match(/title/, mod.const_get(:Exports)::TITLE)
      assert_equal(2, bundle.assets.length)
      assert_equal(bundle.assets.keys, loaded.assets.keys)
    end
  end

  def test_css_class_map_changes_reevaluate_ruby_importers
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      css_path = "#{dir}/styles/home.css"
      File.write(css_path, ".title { color: red; }\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Styles = import("styles/home.css")
          CLASSES = Styles.keys
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      entry_record = context.evaluate("entry")

      assert_equal([:title], context.graph.mods.fetch(entry_record.id).const_get(:Exports)::CLASSES)

      File.write(css_path, ".heading { color: red; }\n")
      result = context.invalidate_paths([css_path])
      classes = context.graph.mods.fetch(entry_record.id).const_get(:Exports)::CLASSES

      assert_equal(["app:/styles/home.css"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["app:/entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      assert_equal([:heading], classes)
    end
  end

  def test_lazy_ruby_import_of_css_defers_asset_until_called
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Styles = lazy_import("styles/home.css")

          def self.title_class
            Styles.call.fetch(:title)
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      entry_record = context.evaluate("entry")
      exports = context.graph.mods.fetch(entry_record.id).const_get(:Exports)

      assert_equal([], context.assets_for("styles/home.css"))
      refute(exports::Styles.loaded?)

      assert_match(/title/, exports.title_class)
      assert_equal(2, context.assets_for("styles/home.css").length)
      assert(exports::Styles.loaded?)
    end
  end

  def test_lazy_css_import_value_updates_after_loaded_css_changes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      css_path = "#{dir}/styles/home.css"
      File.write(css_path, ".title { color: red; }\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Styles = lazy_import("styles/home.css")

          def self.classes
            Styles.call.keys
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      entry_record = context.evaluate("entry")
      exports = context.graph.mods.fetch(entry_record.id).const_get(:Exports)

      assert_equal([:title], exports.classes)

      File.write(css_path, ".heading { color: red; }\n")
      result = context.invalidate_paths([css_path])
      updated_exports = context.graph.mods.fetch(entry_record.id).const_get(:Exports)

      assert_equal(["app:/styles/home.css"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["app:/entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      refute(updated_exports::Styles.loaded?)
      assert_equal([:heading], updated_exports.classes)
    end
  end

  def test_css_source_maps_can_be_disabled
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")

      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin::Plugin.new,
            Klenod::Build::Plugins::CssPlugin::Plugin.new(source_maps: false)
          ]
        )
      record = context.evaluate("styles/home.css")

      assert_equal([:css], record.assets.map { |asset| asset.metadata[:type] })
      refute_includes(record.assets.fetch(0).bytes, "sourceMappingURL")
    end
  end

  def test_css_source_maps_are_emitted_in_development
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("styles/home.css")
      css_asset = record.assets.find { |asset| asset.metadata[:type] == :css }
      map_asset = record.assets.find { |asset| asset.metadata[:type] == :css_source_map }
      source_map = JSON.parse(map_asset.bytes)

      assert_match(%r{\A/assets/styles_home_css\.[a-f0-9]{16}\.css\.map\z}, map_asset.output_path)
      assert_includes(css_asset.bytes, "sourceMappingURL=#{File.basename(map_asset.output_path)}")
      assert_equal(3, source_map.fetch("version"))
      assert_equal(["styles/home.css"], source_map.fetch("sources"))
      assert_equal([".title { color: red; }\n"], source_map.fetch("sourcesContent"))
    end
  end

  def test_css_source_maps_are_not_emitted_in_build_mode_by_default
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir, mode: :build)
      record = context.collect("styles/home.css").record

      assert_equal([:css], record.assets.map { |asset| asset.metadata[:type] })
    end
  end

  def test_css_source_maps_preserve_mappings_after_dependency_rewrites
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/styles/base.css", ".base { color: blue; }\n")
      File.binwrite("#{dir}/images/logo.png", "not really a png")
      File.write(
        "#{dir}/styles/home.css",
        <<~CSS
          @import "./base.css";
          .logo { background: url("../images/logo.png"); }
          .title { color: red; }
        CSS
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("styles/home.css")
      map_asset = record.assets.find { |asset| asset.metadata[:type] == :css_source_map }
      source_map = Klenod::Build::SourceMap::Map.parse(map_asset.bytes)

      assert_equal(["styles/home.css"], source_map.sources)
      assert_equal([1, 2], source_map.segments.map(&:original_line))
      assert_equal([0, 4], source_map.segments.map(&:generated_line))
    end
  end
end
