# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/runtime"

require_relative "../context"

class Klenod::Build::Plugins::JavaScriptPlugin::Test < Minitest::Test
  def test_ruby_import_of_javascript_returns_asset_path_and_emits_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello')\n")
      File.write("#{dir}/entry.rb", "Script = import(\"scripts/app.js\")\nDefault = Script\n")

      context = Klenod::Build::Context.new(source_dir: dir)
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

  def test_runtime_bundle_preserves_javascript_import_value_and_asset_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('bundle')\n")
      File.write("#{dir}/entry.rb", "Script = import(\"scripts/app.js\")\nDefault = Script\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)

      assert_match(%r{\A/assets/scripts_app_js\.[a-f0-9]{16}\.js\z}, loaded.exports("entry")::Default)
      assert_equal(1, bundle.assets.length)
      assert_equal(bundle.assets.keys, loaded.assets.keys)
    end
  end
end
