# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "klenod_context"

class Klenod::ExampleTest < Minitest::Test
  Request = Data.define(:path)

  def test_example_app_loads_renders_and_emits_assets
    source_dir = File.expand_path("src", __dir__)
    context = Example.build_context(source_dir: source_dir)
    entry = context.entry("pages/server")
    status, headers, body = entry.call(nil, context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "<body")
    assert_includes(html, "Klenod example")
    assert_includes(html, "<main")
    assert_includes(html, "<figure")
    assert_includes(html, "Smoked fish")
    assert_includes(html, "srcset=")
    assert_includes(html, "4 modules loaded")
    assert_includes(html, "Main / Dynamic / Layouts / Intercepts")
    assert_includes(html, "v0.1 example")
    assert_includes(html, "Imported from a plain text file.")
    assert_includes(html, "/assets/pages_layout_css")
    assert_includes(html, "/assets/pages_page_css")
    assert_includes(html, "/assets/components_Figure_css")
    assert(context.assets_for("pages/smoked-fish.png").any? { |asset| asset.metadata[:type] == :image_variant })
  end

  def test_example_app_renders_nested_route_through_layout
    source_dir = File.expand_path("src", __dir__)
    context = Example.build_context(source_dir: source_dir)
    entry = context.entry("pages/server")
    status, headers, body = entry.call(Request.new("/blog/hello"), context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "<body")
    assert_includes(html, "Klenod example")
    assert_includes(html, "Blog post: hello")
    assert_includes(html, "Ruby modules loaded through a dependency graph")
  end

  def test_example_app_renders_route_gallery_pages
    source_dir = File.expand_path("src", __dir__)
    context = Example.build_context(source_dir: source_dir)
    entry = context.entry("pages/server")

    assert_route_includes(entry, context, "/docs/guides/routing", "Path parts: guides / routing")
    assert_route_includes(entry, context, "/shop", "No filters selected")
    assert_route_includes(entry, context, "/shop/sale/red", "Filters: sale, red")
    assert_route_includes(entry, context, "/gallery", "Image gallery")
    assert_route_includes(entry, context, "/gallery", "Coffee imported from a routed Haml page.")
    assert_route_includes(entry, context, "/about", "inside a route group")
    assert_route_includes(entry, context, "/dashboard", "Dashboard")
    assert_route_includes(entry, context, "/dashboard", "Dashboard settings modal")
    assert_route_includes(entry, context, "/dashboard/settings", "Dashboard settings modal")
    assert_route_includes(entry, context, "/feed/photo", "Photo intercept")
    assert_route_includes(entry, context, "/profile", "Profile intercept")
    assert_route_includes(entry, context, "/login", "Login intercept")
  end

  def test_example_app_renders_router_tree_metadata
    source_dir = File.expand_path("src", __dir__)
    context = Example.build_context(source_dir: source_dir)
    entry = context.entry("pages/server")
    status, _headers, body = entry.call(Request.new("/routes"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Router gallery")
    assert_includes(html, "Parallel slots: modal")
    assert_includes(html, "(.)photo:intercept_current")
    assert_includes(html, "(..)profile:intercept_parent")
    assert_includes(html, "(...)login:intercept_root")
  end

  def test_example_app_emits_gallery_image_variants
    source_dir = File.expand_path("src", __dir__)
    context = Example.build_context(source_dir: source_dir)
    entry = context.entry("pages/server")
    status, _headers, body = entry.call(Request.new("/gallery"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "srcset=")
    assert(context.assets_for("pages/gallery/coffee.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("pages/gallery/sailing-boat.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("pages/gallery/vegetables.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
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

  private

  def assert_route_includes(entry, context, path, text)
    status, headers, body = entry.call(Request.new(path), context)

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(body.join, text)
  end
end
