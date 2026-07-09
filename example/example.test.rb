# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "klenod_context"

class Klenod::ExampleTest < Minitest::Test
  def test_example_app_loads_renders_and_emits_assets
    source_dir = File.expand_path("src", __dir__)
    context = Example.build_context(source_dir: source_dir)
    entry = context.entry("pages/server")
    status, headers, body = entry.call(nil, context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "<main")
    assert_includes(html, "<figure")
    assert_includes(html, "Smoked fish")
    assert_includes(html, "srcset=")
    assert_includes(html, "/assets/pages_page_css")
    assert_includes(html, "/assets/components_Figure_css")
    assert(context.assets_for("pages/smoked-fish.png").any? { |asset| asset.metadata[:type] == :image_variant })
  end

  def test_example_app_builds_and_loads_runtime_bundle
    source_dir = File.expand_path("src", __dir__)

    Dir.mktmpdir do |dir|
      output = "#{dir}/klenod.bundle"
      assets_dir = "#{dir}/public"
      context = Example.build_context(source_dir: source_dir)
      bundle = context.build(entrypoints: ["pages/server"], output: output, assets_dir: assets_dir)
      loaded = Klenod::Runtime.load_bundle(output)
      page = loaded.exports("pages/server")
      status, _headers, body = page.call(nil, loaded)

      assert_equal(200, status)
      assert_includes(body.join, "<main")
      assert_equal(bundle.assets.keys.sort, loaded.assets.keys.sort)
      loaded.each_asset do |asset|
        disk_path = File.join(assets_dir, asset.output_path.delete_prefix("/"))

        assert(File.exist?(disk_path), "Expected #{disk_path} to exist")
      end
    end
  end
end
