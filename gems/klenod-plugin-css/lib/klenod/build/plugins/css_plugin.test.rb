# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/build/context"
require "klenod/plugin/css"
require "klenod/runtime"
require "klenod/build/plugins/image_plugin"

class Klenod::Build::Plugins::CSSPlugin::Test < Minitest::Test
  def test_namespace_constructs_the_plugin
    assert_instance_of Klenod::Build::Plugins::CSSPlugin::Plugin, Klenod::Build::Plugins::CSSPlugin.new
  end

  def test_ruby_import_of_css_returns_class_map_and_emits_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write("#{dir}/pages/home.rb", "Styles = import(\"../styles/home.css\")\nTITLE = Styles.fetch(:title)\n")

      context = context_for(dir)
      record = context.evaluate("pages/home")
      mod = context.graph.mods.fetch(record.id)
      css_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/home.css", nil))

      assert_match(/title/, mod.const_get(:Exports)::TITLE)
      css_asset = css_record.assets.find { |asset| asset.metadata[:type] == :css }

      assert_match(%r{\A/styles_home_css\.[a-f0-9]{16}\.css\z}, css_asset.output_path)
      assert_includes(css_asset.bytes, "color: red")
    end
  end

  def test_css_import_resolution_errors_include_the_source_location
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/reset.css", "body { margin: 0; }\n")
      File.write("#{dir}/styles/main.css", "@import \"./resett.css\";\n")
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/main.css\")\n")

      error = assert_raises(Klenod::Build::ResolveError) { context_for(dir).evaluate("entry") }

      assert_equal("./resett.css", error.requested_specifier)
      assert_equal(["./reset.css"], error.suggestions)
      assert_equal(Klenod::Build::SourceLocation.new("app:/styles/main.css", 1, 9), error.source_location)
    end
  end

  def test_css_asset_urls_use_the_configured_asset_base
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/logo.svg", '<svg width="1" height="1"/>')
      File.write("#{dir}/styles/home.css", '.logo { background-image: url("./logo.svg"); }')
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/home.css\")\n")

      context = context_for(dir, base: "/.assets")
      context.evaluate("entry")
      css_asset = context.assets_for("styles/home.css").find { it.metadata[:type] == :css }
      svg_asset = context.assets_for("styles/logo.svg").find { it.metadata[:type] == :svg }

      assert_includes(css_asset.bytes, "/.assets#{svg_asset.output_path}")
      assert_equal("/.assets#{css_asset.output_path}", css_asset.url)
    end
  end

  def test_css_class_map_resolves_local_global_and_dependency_compositions
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/typography.css", ".typography { font-weight: 700; }\n")
      File.write(
        "#{dir}/styles/heading.css",
        <<~CSS
          .heading { composes: typography from "./typography.css"; color: gray; }
          .title { composes: heading; }
          .external { composes: utility from global; }
        CSS
      )
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Styles = import("styles/heading.css")
          TITLE = Styles.fetch(:title)
          EXTERNAL = Styles.fetch(:external)
        RUBY
      )

      context = context_for(dir)
      entry_record = context.evaluate("entry")
      exports = context.graph.mods.fetch(entry_record.id).const_get(:Exports)
      heading_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/heading.css", nil))
      typography_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/typography.css", nil))
      raw_classes = heading_record.metadata.fetch(:css_result).classes
      typography_class = typography_record.metadata.fetch(:css_classes).fetch(:typography)

      assert_equal(
        [raw_classes.fetch(:title), raw_classes.fetch(:heading), typography_class],
        exports::TITLE.split
      )
      assert_equal([raw_classes.fetch(:external), "utility"], exports::EXTERNAL.split)
      assert_includes(
        heading_record.resolved_dependencies.map { [it.dependency.kind, it.module_id.to_s] },
        [:css_compose, "app:/styles/typography.css"]
      )
      assert_equal(
        ["styles/typography.css", "styles/heading.css"],
        context.assets_for_module(entry_record, type: :css).map(&:logical_name)
      )
    end
  end

  def test_runtime_bundle_preserves_composed_css_class_map
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/typography.css", ".typography { font-weight: 700; }\n")
      File.write(
        "#{dir}/styles/heading.css",
        ".heading { composes: typography from \"./typography.css\"; color: gray; }\n"
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/heading.css\")\nHEADING = Styles.fetch(:heading)\n")
      output = "#{dir}/bundle.mpk"

      context = context_for(dir, mode: :build)
      context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      heading = loaded.exports("entry")::HEADING
      typography_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/typography.css", nil))

      assert_equal(2, heading.split.length)
      assert_includes(heading.split, typography_record.metadata.fetch(:css_classes).fetch(:typography))
      assert_equal(
        ["styles/typography.css", "styles/heading.css"],
        loaded.assets_for_module("entry.rb", type: :css).map(&:logical_name)
      )
    end
  end

  def test_composing_a_missing_css_class_reports_a_build_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/typography.css", ".body { font-weight: 400; }\n")
      File.write(
        "#{dir}/styles/heading.css",
        ".heading { composes: typography from \"./typography.css\"; }\n"
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/heading.css\")\n")

      error = assert_raises(Klenod::Build::UnsupportedFileError) do
        context_for(dir).collect("entry")
      end

      assert_includes(error.message, "class :typography")
      assert_includes(error.message, 'from "./typography.css"')
      assert_includes(error.message, "module app:/styles/typography.css does not export it")
    end
  end

  def test_local_css_variables_resolve_file_and_global_references
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/vars.css", ":root { --accent-color: rebeccapurple; }\n")
      File.write(
        "#{dir}/styles/button.css",
        <<~CSS
          .button {
            background: var(--accent-color from "./vars.css");
            border-color: var(--accent-color from "./vars.css");
            color: var(--text-color from global);
          }
        CSS
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/button.css\")\n")

      context = context_for(dir, css_plugin: local_css_variables_plugin)
      entry_record = context.evaluate("entry")
      button_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/button.css", nil))
      vars_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/vars.css", nil))
      variable = vars_record.metadata.fetch(:css_variables).fetch("--accent-color")
      button_css = button_record.assets.find { it.metadata[:type] == :css }.bytes
      vars_css = vars_record.assets.find { it.metadata[:type] == :css }.bytes

      assert_includes(vars_css, variable)
      assert_equal(2, button_css.scan("var(#{variable})").length)
      assert_includes(button_css, "var(--text-color)")
      assert_includes(
        button_record.resolved_dependencies.map { [it.dependency.kind, it.module_id.to_s] },
        [:css_variable, "app:/styles/vars.css"]
      )
      assert_equal(
        ["styles/vars.css", "styles/button.css"],
        context.assets_for_module(entry_record, type: :css).map(&:logical_name)
      )
    end
  end

  def test_runtime_bundle_preserves_local_css_variable_dependencies
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/vars.css", ":root { --accent-color: red; }\n")
      File.write(
        "#{dir}/styles/button.css",
        ".button { color: var(--accent-color from \"./vars.css\"); }\n"
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/button.css\")\n")
      output = "#{dir}/bundle.mpk"

      context = context_for(dir, mode: :build, css_plugin: local_css_variables_plugin)
      context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      button_asset = loaded.assets_for("styles/button.css").find { it.metadata[:type] == :css }
      vars_asset = loaded.assets_for("styles/vars.css").find { it.metadata[:type] == :css }

      assert(vars_asset.metadata.fetch(:variables).key?("--accent-color"))
      assert_equal(
        ["styles/vars.css", "styles/button.css"],
        loaded.assets_for_module("entry", type: :css).map(&:logical_name)
      )
      assert_includes(
        loaded.modules.fetch("app:/styles/button.css").imports.values.map(&:target_id),
        "app:/styles/vars.css"
      )
      assert_equal({}, button_asset.metadata.fetch(:variables))
    end
  end

  def test_local_css_variables_are_disabled_by_default
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write(
        "#{dir}/styles/button.css",
        ":root { --accent-color: red; } .button { color: var(--accent-color); }\n"
      )

      record = context_for(dir).collect("styles/button.css").record
      css = record.assets.find { it.metadata[:type] == :css }.bytes

      assert_equal({}, record.metadata.fetch(:css_variables))
      assert_includes(css, "--accent-color")
    end
  end

  def test_missing_local_css_variable_reports_a_build_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/vars.css", ":root { --other-color: red; }\n")
      File.write(
        "#{dir}/styles/button.css",
        ".button { color: var(--accent-color from \"./vars.css\"); }\n"
      )

      error = assert_raises(Klenod::Build::UnsupportedFileError) do
        context_for(dir, css_plugin: local_css_variables_plugin).collect("styles/button.css")
      end

      assert_includes(error.message, 'CSS variable "--accent-color"')
      assert_includes(error.message, 'from "./vars.css"')
      assert_includes(error.message, "module app:/styles/vars.css")
    end
  end

  def test_css_can_be_minified_in_development
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")

      context = context_for(dir, css_plugin: Klenod::Build::Plugins::CSSPlugin.new(minify: true))
      record = context.evaluate("styles/home.css")
      css_asset = record.assets.find { |asset| asset.metadata[:type] == :css }

      assert_includes(css_asset.bytes, "color:red")
    end
  end

  def test_css_source_is_read_as_utf_8
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title::before { content: \"🌗\"; }\n", encoding: "UTF-8")
      File.write("#{dir}/pages/home.rb", "Styles = import(\"../styles/home.css\")\n")

      context = context_for(dir)
      context.evaluate("pages/home")
      css_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/home.css", nil))
      css_asset = css_record.assets.find { it.metadata[:type] == :css }

      assert_includes(css_asset.bytes, "🌗")
    end
  end

  def test_javascript_stylesheet_css_module_emits_only_unscoped_stylesheet
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\nimg { display: block; }\n")

      context = context_for(dir)
      record = context.evaluate("styles/home.css?javascript")
      css_asset = record.assets.find { it.metadata[:type] == :css }
      javascript_css_asset = record.assets.find { it.metadata[:type] == :css_javascript_stylesheet }

      assert_nil(css_asset)
      assert_equal(javascript_css_asset.url, record.metadata.fetch(:css_javascript_stylesheet_path))
      assert_match(%r{\A/styles_home_css\.javascript\.[a-f0-9]{16}\.css\z}, javascript_css_asset.output_path)
      assert_includes(javascript_css_asset.bytes, ".title")
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

      context = context_for(dir)
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

      context = context_for(dir)
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

      context = context_for(dir)
      record = context.evaluate("styles/home.css")
      css = record.assets.first.bytes

      refute_includes(css, "@import")
      refute_includes(css, "/assets/styles_base_css")
      assert_includes(css, "/assets/logo.")
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("styles/home.css", nil)))
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("styles/base.css", nil)))
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("images/logo.png", nil)))
    end
  end

  def test_minified_css_removes_consecutive_empty_imports
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/first.css", ".first { color: red; }\n")
      File.write("#{dir}/styles/second.css", ".second { color: blue; }\n")
      File.write(
        "#{dir}/styles/home.css",
        "@import \"./first.css\";\n@import \"./second.css\";\n.home { color: green; }\n"
      )
      plugin = Klenod::Build::Plugins::CSSPlugin.new(minify: true, source_maps: false)

      record = context_for(dir, css_plugin: plugin).evaluate("styles/home.css")

      refute_includes(record.assets.fetch(0).bytes, "@import")
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

      context = context_for(dir)
      record = context.evaluate("styles/home.css")
      css = record.assets.first.bytes

      assert_includes(css, font_url)
      assert_equal(["app:/styles/home.css"], context.graph.records.keys.map(&:to_s).grep_v(/\Avirtual:/))
    end
  end

  def test_css_importing_css_emits_scoped_assets_in_bundle_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/base.css", ".base { color: blue; }\n")
      File.write("#{dir}/styles/home.css", "@import \"./base.css\";\n.title { color: red; }\n")

      context = context_for(dir)
      bundle = context.build(entrypoints: ["styles/home.css"], output: "#{dir}/bundle.mpk")
      home_asset = context.assets_for("styles/home.css").fetch(0)
      base_asset = context.assets_for("styles/base.css").fetch(0)

      refute_includes(home_asset.bytes, "@import")
      refute_includes(home_asset.bytes, base_asset.output_path)
      assert_match(%r{\A/styles_home_css\.[a-f0-9]{16}\.css\z}, home_asset.output_path)
      assert_match(%r{\A/styles_base_css\.[a-f0-9]{16}\.css\z}, base_asset.output_path)
      assert_equal(4, bundle.assets.length)
    end
  end

  def test_css_importing_ruby_raises_unsupported_file_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/dep.rb", "VALUE = 1\n")
      File.write("#{dir}/styles/home.css", "@import \"./dep.rb\";\n.title { color: red; }\n")

      error = assert_raises(Klenod::Build::UnsupportedFileError) do
        context_for(dir).evaluate("styles/home.css")
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
        context_for(dir).evaluate("styles/home.css")
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

      context = context_for(dir)
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

      context = context_for(dir)
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

      context = context_for(dir)
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

  def test_composed_css_dependency_change_refinalizes_consumer_and_reevaluates_importers
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      typography_path = "#{dir}/styles/typography.css"
      File.write(typography_path, ".typography { color: red; }\n")
      File.write(
        "#{dir}/styles/heading.css",
        ".heading { composes: typography from \"./typography.css\"; color: gray; }\n"
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/heading.css\")\nHEADING = Styles.fetch(:heading)\n")

      context = context_for(dir)
      entry_record = context.evaluate("entry")
      old_heading = context.graph.mods.fetch(entry_record.id).const_get(:Exports)::HEADING

      File.write(typography_path, ".typography { color: blue; }\n")
      result = context.invalidate_paths([typography_path])
      new_heading = context.graph.mods.fetch(entry_record.id).const_get(:Exports)::HEADING
      typography_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/typography.css", nil))

      assert_equal(["app:/styles/typography.css"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["app:/styles/heading.css", "app:/entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      refute_equal(old_heading, new_heading)
      assert_includes(new_heading.split, typography_record.metadata.fetch(:css_classes).fetch(:typography))
    end
  end

  def test_local_css_variable_change_refinalizes_consumer_and_reevaluates_importers
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      vars_path = "#{dir}/styles/vars.css"
      File.write(vars_path, ":root { --accent-color: red; }\n")
      File.write(
        "#{dir}/styles/button.css",
        ".button { color: var(--accent-color from \"./vars.css\"); }\n"
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/button.css\")\n")

      context = context_for(dir, css_plugin: local_css_variables_plugin)
      context.evaluate("entry")
      button_id = Klenod::Build::ModuleId.new("styles/button.css", nil)
      old_css = context.graph.records.fetch(button_id).assets.find { it.metadata[:type] == :css }.bytes

      File.write(vars_path, ":root { --accent-color: blue; }\n")
      result = context.invalidate_paths([vars_path])
      vars_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/vars.css", nil))
      new_css = context.graph.records.fetch(button_id).assets.find { it.metadata[:type] == :css }.bytes
      variable = vars_record.metadata.fetch(:css_variables).fetch("--accent-color")

      assert_equal(["app:/styles/vars.css"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["app:/styles/button.css", "app:/entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      refute_equal(old_css, new_css)
      assert_includes(new_css, "var(#{variable})")
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

      context = context_for(dir)
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

      context = context_for(dir)
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
        context_for(
          dir,
          css_plugin: Klenod::Build::Plugins::CSSPlugin.new(source_maps: false)
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

      context = context_for(dir)
      record = context.evaluate("styles/home.css")
      css_asset = record.assets.find { |asset| asset.metadata[:type] == :css }
      map_asset = record.assets.find { |asset| asset.metadata[:type] == :css_source_map }
      source_map = JSON.parse(map_asset.bytes)

      assert_match(%r{\A/styles_home_css\.[a-f0-9]{16}\.css\.map\z}, map_asset.output_path)
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

      context = context_for(dir, mode: :build)
      record = context.collect("styles/home.css").record

      assert_equal([:css], record.assets.map { |asset| asset.metadata[:type] })
      assert_includes(record.assets.fetch(0).bytes, "color:red")
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

      context = context_for(dir)
      record = context.evaluate("styles/home.css")
      map_asset = record.assets.find { |asset| asset.metadata[:type] == :css_source_map }
      source_map = Klenod::Build::SourceMap::Map.parse(map_asset.bytes)

      assert_equal(["styles/home.css"], source_map.sources)
      assert_equal([1, 2], source_map.segments.map(&:original_line))
      assert_equal([0, 4], source_map.segments.map(&:generated_line))
    end
  end

  private

  def context_for(dir, mode: :development, base: "/assets/", css_plugin: Klenod::Build::Plugins::CSSPlugin.new)
    Klenod::Build::Context.new(
      source_dir: dir,
      mode: mode,
      base: base,
      plugins: [
        *Klenod::Build::Context.default_plugins,
        css_plugin
      ]
    )
  end

  def local_css_variables_plugin
    Klenod::Build::Plugins::CSSPlugin.new(local_css_variables: true)
  end
end
