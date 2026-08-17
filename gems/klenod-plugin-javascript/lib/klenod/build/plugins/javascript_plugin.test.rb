# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require "klenod/build/source_map"
require "klenod/plugin/javascript"
require "klenod/runtime"

class Klenod::Build::Plugins::JavaScriptPlugin::Test < Minitest::Test
  def test_ruby_import_of_javascript_returns_asset_path_and_emits_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello')\n")
      File.write("#{dir}/entry.rb", "Script = import(\"scripts/app.js\")\nDefault = Script\n")

      context = context_for(dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = context.assets_for_module(record, type: :javascript).fetch(0)

      assert_match(%r{\A/assets/scripts_app_js\.[a-f0-9]{16}\.js\z}, exports::Default)
      assert_equal(exports::Default, asset.output_path)
      assert_equal("scripts/app.js", asset.logical_name)
      assert_equal("application/javascript", asset.content_type)
      assert_equal(:javascript, asset.metadata.fetch(:type))
      assert_includes(asset.bytes, "console.log('hello')\n")
    end
  end

  def test_static_relative_imports_are_rewritten_to_hashed_asset_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import message from './message.js';\nconsole.log(message);\n")
      File.write("#{dir}/scripts/message.js", "export default 'hello';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      message_asset = javascript_asset(context, "scripts/message.js")

      assert_includes(app_asset.bytes, "from '#{message_asset.output_path}'")
    end
  end

  def test_re_exports_are_rewritten_to_hashed_asset_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "export { value } from './dep.js';\n")
      File.write("#{dir}/scripts/dep.js", "export const value = 1;\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      dep_asset = javascript_asset(context, "scripts/dep.js")

      assert_includes(app_asset.bytes, "from '#{dep_asset.output_path}'")
    end
  end

  def test_literal_dynamic_imports_are_rewritten_to_hashed_asset_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "button.addEventListener('click', () => import('./panel.js'));\n")
      File.write("#{dir}/scripts/panel.js", "export default 'panel';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      panel_asset = javascript_asset(context, "scripts/panel.js")

      assert_includes(app_asset.bytes, "import('#{panel_asset.output_path}')")
    end
  end

  def test_extensionless_relative_javascript_imports_resolve_to_js_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import './boot';\n")
      File.write("#{dir}/scripts/boot.js", "console.log('boot');\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      boot_asset = javascript_asset(context, "scripts/boot.js")

      assert_includes(app_asset.bytes, "import '#{boot_asset.output_path}'")
    end
  end

  def test_external_url_imports_are_left_unchanged
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import 'https://cdn.example.com/app.js';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")

      assert_includes(app_asset.bytes, "import 'https://cdn.example.com/app.js'")
      assert_equal(1, context.assets_for("scripts/app.js").count { it.metadata.fetch(:type) == :javascript })
    end
  end

  def test_bare_specifiers_raise_clear_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import React from 'react';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      error = assert_raises(Klenod::Build::DynamicImportError) do
        context_for(dir).evaluate("entry")
      end

      assert_includes(error.message, "Unsupported JavaScript import \"react\"")
      assert_includes(error.message, "Only relative, app-root, and external URL imports are supported")
    end
  end

  def test_runtime_bundle_preserves_javascript_import_value_and_asset_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import './dep.js';\nconsole.log('bundle')\n")
      File.write("#{dir}/scripts/dep.js", "console.log('dep')\n")
      File.write("#{dir}/entry.rb", "Script = import(\"scripts/app.js\")\nDefault = Script\n")
      output = "#{dir}/bundle.mpk"

      context = context_for(dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)

      assert_match(%r{\A/assets/scripts_app_js\.[a-f0-9]{16}\.js\z}, loaded.exports("entry")::Default)
      assert_equal(2, bundle.assets.count { |_path, asset| asset.metadata.fetch(:type) == :javascript })
      assert_equal(bundle.assets.keys, loaded.assets.keys)
    end
  end

  def test_javascript_source_maps_can_be_disabled
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello');\n")

      context = context_for(dir, javascript_plugin: Klenod::Build::Plugins::JavaScriptPlugin::Plugin.new(source_maps: false))
      record = context.evaluate("scripts/app.js")

      assert_equal([:javascript], record.assets.map { it.metadata.fetch(:type) })
      refute_includes(record.assets.fetch(0).bytes, "sourceMappingURL")
    end
  end

  def test_javascript_source_maps_are_emitted_in_development
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      source = "console.log('hello');\n"
      File.write("#{dir}/scripts/app.js", source)

      context = context_for(dir)
      record = context.evaluate("scripts/app.js")
      js_asset = record.assets.find { it.metadata.fetch(:type) == :javascript }
      map_asset = record.assets.find { it.metadata.fetch(:type) == :javascript_source_map }
      source_map = JSON.parse(map_asset.bytes)

      assert_match(%r{\A/assets/scripts_app_js\.[a-f0-9]{16}\.js\.map\z}, map_asset.output_path)
      assert_includes(js_asset.bytes, "sourceMappingURL=#{File.basename(map_asset.output_path)}")
      assert_equal(3, source_map.fetch("version"))
      assert_equal(["scripts/app.js"], source_map.fetch("sources"))
      assert_equal([source], source_map.fetch("sourcesContent"))
    end
  end

  def test_javascript_source_maps_are_not_emitted_in_build_mode_by_default
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello');\n")

      context = context_for(dir, mode: :build)
      record = context.collect("scripts/app.js").record

      assert_equal([:javascript], record.assets.map { it.metadata.fetch(:type) })
    end
  end

  def test_javascript_source_maps_preserve_mappings_after_dependency_rewrites
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/dep.js", "export const dep = 1;\n")
      File.write(
        "#{dir}/scripts/app.js",
        <<~JS
          import { dep } from "./dep.js";
          console.log(dep);
          console.log("done");
        JS
      )

      context = context_for(dir)
      record = context.evaluate("scripts/app.js")
      map_asset = record.assets.find { it.metadata.fetch(:type) == :javascript_source_map }
      source_map = Klenod::Build::SourceMap::Map.parse(map_asset.bytes)

      assert_equal(["scripts/app.js"], source_map.sources)
      assert_equal([0, 1, 2, 3], source_map.segments.map(&:original_line))
      assert_equal([0, 1, 2, 3], source_map.segments.map(&:generated_line))
    end
  end

  def test_typescript_import_emits_javascript_asset
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.ts", "const message: string = 'hello';\nexport default message;\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      record = context.evaluate("entry")
      asset = javascript_asset(context, "scripts/app.ts")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_match(%r{\A/assets/scripts_app_ts\.[a-f0-9]{16}\.js\z}, exports::Default)
      assert_equal("scripts/app.ts", asset.logical_name)
      assert_includes(asset.bytes, "const message = 'hello'")
      refute_includes(asset.bytes, ": string")
    end
  end

  def test_typescript_static_imports_are_rewritten_to_hashed_asset_paths
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.ts", "import { message } from './message';\nconsole.log(message);\n")
      File.write("#{dir}/scripts/message.ts", "export const message: string = 'hello';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.ts")
      message_asset = javascript_asset(context, "scripts/message.ts")

      assert_includes(app_asset.bytes, "from '#{message_asset.output_path}'")
    end
  end

  def test_typescript_can_import_javascript_with_explicit_extension
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.ts", "import './boot.js';\n")
      File.write("#{dir}/scripts/boot.js", "console.log('boot');\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.ts")
      boot_asset = javascript_asset(context, "scripts/boot.js")

      assert_includes(app_asset.bytes, "import '#{boot_asset.output_path}'")
    end
  end

  def test_typescript_source_maps_reference_original_typescript
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      source = "const message: string = 'hello';\n"
      File.write("#{dir}/scripts/app.ts", source)

      context = context_for(dir)
      record = context.evaluate("scripts/app.ts")
      map_asset = record.assets.find { it.metadata.fetch(:type) == :javascript_source_map }
      source_map = JSON.parse(map_asset.bytes)

      assert_equal(["scripts/app.ts"], source_map.fetch("sources"))
      assert_equal([source], source_map.fetch("sourcesContent"))
    end
  end

  private

  def context_for(dir, mode: :development, javascript_plugin: Klenod::Build::Plugins::JavaScriptPlugin::Plugin.new)
    Klenod::Build::Context.new(
      source_dir: dir,
      mode: mode,
      plugins: [
        *Klenod::Build::Context.default_plugins,
        javascript_plugin
      ]
    )
  end

  def javascript_asset(context, logical_name)
    context.assets_for(logical_name).find { it.metadata.fetch(:type) == :javascript } || flunk("Missing asset for #{logical_name}")
  end
end
