# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

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
      assert_equal("console.log('hello')\n", asset.bytes)
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
      assert_equal(1, context.assets_for("scripts/app.js").length)
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
      assert_equal(2, bundle.assets.length)
      assert_equal(bundle.assets.keys, loaded.assets.keys)
    end
  end

  private

  def context_for(dir)
    Klenod::Build::Context.new(
      source_dir: dir,
      plugins: [
        *Klenod::Build::Context.default_plugins,
        Klenod::Build::Plugins::JavaScriptPlugin::Plugin.new
      ]
    )
  end

  def javascript_asset(context, logical_name)
    context.assets_for(logical_name).find { it.metadata.fetch(:type) == :javascript } || flunk("Missing asset for #{logical_name}")
  end
end
