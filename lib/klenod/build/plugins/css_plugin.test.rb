# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require_relative "image_plugin"

class Klenod::Build::Plugins::CssPlugin::Test < Minitest::Test
  def test_ruby_import_of_css_returns_class_map_and_emits_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write("#{dir}/pages/home.rb", "Styles = import(\"../styles/home.css\")\nTITLE = Styles.fetch(\"title\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/home")
      mod = context.graph.mods.fetch(record.id)
      css_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("styles/home.css", nil))

      assert_match(/title/, mod.const_get(:Exports)::TITLE)
      assert_equal(1, css_record.assets.length)
      assert_match(%r{\A/assets/styles_home_css\.[a-f0-9]{16}\.css\z}, css_record.assets.first.output_path)
      assert_includes(css_record.assets.first.bytes, "color: red")
    end
  end

  def test_css_dependencies_replace_import_and_url_placeholders
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
      record = context.load("styles/home.css")
      css = record.assets.first.bytes

      assert_includes(css, "/assets/styles_base_css")
      assert_includes(css, "/assets/logo.")
      assert_equal(3, context.graph.records.length)
    end
  end

  def test_runtime_bundle_preserves_css_import_value_and_asset_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/home.css\")\nTITLE = Styles.fetch(\"title\")\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      mod = loaded.load("entry")

      assert_match(/title/, mod.const_get(:Exports)::TITLE)
      assert_equal(1, bundle.assets.length)
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
      entry_record = context.load("entry")

      assert_equal(["title"], context.graph.mods.fetch(entry_record.id).const_get(:Exports)::CLASSES)

      File.write(css_path, ".heading { color: red; }\n")
      result = context.invalidate_paths([css_path])
      classes = context.graph.mods.fetch(entry_record.id).const_get(:Exports)::CLASSES

      assert_equal(["styles/home.css"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      assert_equal(["heading"], classes)
    end
  end
end
