# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../runtime"
require_relative "context"

class Klenod::Build::Context::Test < Minitest::Test
  def test_loads_entrypoint_and_dependencies_lazily
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write("#{dir}/pages/page.rb", "Dep = import(\"../dep\")\nVALUE = Dep::VALUE + 1\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/page")
      mod = context.graph.mods.fetch(record.id)

      assert_equal(42, mod.const_get(:Exports)::VALUE)
      assert_equal(2, context.graph.records.length)
    end
  end

  def test_build_writes_marshal_bundle
    Dir.mktmpdir do |dir|
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write("#{dir}/entry.rb", "Dep = import(\"dep\")\nVALUE = Dep::VALUE + 1\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      mod = loaded.load("entry")

      assert_equal(bundle.entrypoints, loaded.entrypoints)
      assert_equal(2, loaded.modules.length)
      assert_equal(42, mod.const_get(:Exports)::VALUE)
    end
  end

  def test_build_writes_css_assets_to_assets_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/home.css\")\nTITLE = Styles.fetch(:title)\n")
      output = "#{dir}/dist/klenod.bundle"
      assets_dir = "#{dir}/dist/public"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output, assets_dir: assets_dir)
      asset_path, runtime_asset = bundle.assets.first
      asset = context.asset(asset_path)
      written_path = File.join(assets_dir, asset_path.delete_prefix("/"))

      assert_match(%r{\A/assets/styles_home_css\.[a-f0-9]{16}\.css\z}, asset_path)
      assert_equal(asset.bytes, File.binread(written_path))
      assert_equal("text/css", runtime_asset.content_type)
      assert_equal(context.asset(asset_path), context.assets.fetch(asset_path))
      assert_equal([asset.logical_name], context.assets_for("styles/home.css").map(&:logical_name))
      assert_includes(context.each_asset.to_a.map(&:output_path), asset_path)
    end
  end

  def test_invalidate_paths_reports_asset_changes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      css_path = "#{dir}/styles/home.css"
      File.write(css_path, ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.load("styles/home.css")
      old_asset_path = context.assets_for("styles/home.css").first.output_path

      File.write(css_path, ".title { color: blue; }\n")
      result = context.invalidate_paths([css_path])
      new_asset_path = context.assets_for("styles/home.css").first.output_path

      assert_equal([new_asset_path], result.added_assets)
      assert_equal([old_asset_path], result.removed_assets)
      assert_equal([], result.changed_assets)
      assert_equal([new_asset_path], result.asset_changes.added)
      assert_equal([old_asset_path], result.asset_changes.removed)
      assert_equal([], result.asset_changes.changed)
      assert_equal([new_asset_path, old_asset_path], result.asset_changes.paths)
      refute(result.asset_changes.empty?)
    end
  end

  def test_build_writes_image_assets_to_assets_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", "png bytes")
      File.write(
        "#{dir}/styles/home.css",
        ".logo { background: url(\"../images/logo.png\"); }\n"
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/home.css\")\n")
      output = "#{dir}/dist/klenod.bundle"
      assets_dir = "#{dir}/dist/public"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output, assets_dir: assets_dir)
      image_asset =
        bundle.assets.values.find { |asset| asset.content_type == "image/png" }
      written_path = File.join(assets_dir, image_asset.output_path.delete_prefix("/"))

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.png\z}, image_asset.output_path)
      assert_equal("png bytes", File.binread(written_path))
    end
  end

  def test_invalidate_paths_reloads_changed_module_and_reevaluates_dependents
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 41\n")
      File.write("#{dir}/pages/page.rb", "Dep = import(\"../dep\")\nVALUE = Dep::VALUE + 1\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/page")

      assert_equal(42, context.graph.mods.fetch(record.id).const_get(:Exports)::VALUE)

      File.write(dep_path, "VALUE = 99\n")

      result = context.invalidate_paths([dep_path])
      updated_record = context.graph.records.fetch(record.id)
      updated_mod = context.graph.mods.fetch(record.id)

      assert_equal(["dep.rb"], result.changed_module_ids.map(&:to_s))
      assert_equal(["dep.rb"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["pages/page.rb"], result.reevaluated_module_ids.map(&:to_s))
      assert_equal(100, updated_mod.const_get(:Exports)::VALUE)
      assert_equal(1, updated_record.version)
    end
  end

  def test_invalidate_paths_removes_deleted_module_and_reports_dependent_error
    Dir.mktmpdir do |dir|
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 1\n")
      File.write("#{dir}/entry.rb", "Dep = import(\"dep\")\nVALUE = Dep::VALUE\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.load("entry")

      File.delete(dep_path)

      result = context.invalidate_paths([], removed_paths: [dep_path])

      assert_equal(["dep.rb"], result.removed_module_ids.map(&:to_s))
      assert_equal(["entry.rb"], result.errors.map { |module_id, _error| module_id.to_s })
    end
  end
end
