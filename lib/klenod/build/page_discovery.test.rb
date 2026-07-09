# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "context"
require_relative "errors"
require_relative "page_discovery"

class Klenod::Build::PageDiscovery::Test < Minitest::Test
  def test_discovers_root_and_nested_page_routes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog")
      FileUtils.mkdir_p("#{dir}/pages/components")
      File.write("#{dir}/pages/page.haml", "")
      File.write("#{dir}/pages/blog/page.rb", "")
      File.write("#{dir}/pages/layout.haml", "")
      File.write("#{dir}/pages/components/Card.haml", "")

      manifest = Klenod::Build::PageDiscovery.new(source_dir: dir).call
      routes = manifest.routes

      assert_equal(
        [
          ["/", Klenod::Build::ModuleId.new("pages/page.haml", nil)],
          ["/blog", Klenod::Build::ModuleId.new("pages/blog/page.rb", nil)]
        ],
        routes.map { |route| [route.path, route.module_id] }
      )
      assert_equal(["pages/page.haml", "pages/blog/page.rb"], manifest.entrypoints)
      assert_equal(routes.fetch(1), manifest.fetch("/blog"))
      assert_equal(routes, manifest.each_route.to_a)
      assert_equal([], routes.fetch(0).segments)
      assert_equal([[:blog, :static, nil, "blog"]], segment_values(routes.fetch(1)))
      assert_equal([Klenod::Build::ModuleId.new("pages/layout.haml", nil)], routes.fetch(0).layout_module_ids)
      assert_equal([Klenod::Build::ModuleId.new("pages/layout.haml", nil)], routes.fetch(1).layout_module_ids)
    end
  end

  def test_context_exposes_page_routes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/app/about")
      File.write("#{dir}/app/about/page.haml", "")

      context = Klenod::Build::Context.new(source_dir: dir)
      routes = context.page_routes(pages_dir: "app")
      manifest = context.route_manifest(pages_dir: "app")

      assert_equal("/about", routes.fetch(0).path)
      assert_equal(Klenod::Build::ModuleId.new("app/about/page.haml", nil), routes.fetch(0).module_id)
      assert_equal(routes, manifest.routes)
    end
  end

  def test_discovers_structured_route_segments
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog/[slug]")
      FileUtils.mkdir_p("#{dir}/pages/docs/[...parts]")
      FileUtils.mkdir_p("#{dir}/pages/shop/[[...filters]]")
      FileUtils.mkdir_p("#{dir}/pages/(marketing)/about")
      FileUtils.mkdir_p("#{dir}/pages/dashboard/@modal/settings")
      File.write("#{dir}/pages/blog/[slug]/page.haml", "")
      File.write("#{dir}/pages/docs/[...parts]/page.haml", "")
      File.write("#{dir}/pages/shop/[[...filters]]/page.haml", "")
      File.write("#{dir}/pages/(marketing)/about/page.haml", "")
      File.write("#{dir}/pages/dashboard/@modal/settings/page.haml", "")

      routes = Klenod::Build::PageDiscovery.new(source_dir: dir).call.routes
      routes_by_path = routes.to_h { |route| [route.path, route] }

      assert_equal([:static, :dynamic], routes_by_path.fetch("/blog/:slug").segments.map(&:kind))
      assert_equal("slug", routes_by_path.fetch("/blog/:slug").segments.fetch(1).param_name)
      assert_equal([Klenod::Build::RouteParam.new("slug", :dynamic)], routes_by_path.fetch("/blog/:slug").params)
      assert_equal("/docs/*parts", routes_by_path.fetch("/docs/*parts").path)
      assert_equal(:catch_all, routes_by_path.fetch("/docs/*parts").segments.fetch(1).kind)
      assert_equal([Klenod::Build::RouteParam.new("parts", :catch_all)], routes_by_path.fetch("/docs/*parts").params)
      assert_equal("/shop", routes_by_path.fetch("/shop").path)
      assert_equal(:optional_catch_all, routes_by_path.fetch("/shop").segments.fetch(1).kind)
      assert_equal([Klenod::Build::RouteParam.new("filters", :optional_catch_all)], routes_by_path.fetch("/shop").params)
      assert_equal("/about", routes_by_path.fetch("/about").path)
      assert_equal(:group, routes_by_path.fetch("/about").segments.fetch(0).kind)
      assert_equal([], routes_by_path.fetch("/about").params)
      assert_equal("/dashboard/settings", routes_by_path.fetch("/dashboard/settings").path)
      assert_equal(:parallel, routes_by_path.fetch("/dashboard/settings").segments.fetch(1).kind)
      assert_equal("modal", routes_by_path.fetch("/dashboard/settings").segments.fetch(1).param_name)
      assert_equal([], routes_by_path.fetch("/dashboard/settings").params)
    end
  end

  def test_discovers_layout_ancestry_without_loading_layout_modules
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog/post")
      FileUtils.mkdir_p("#{dir}/pages/docs")
      File.write("#{dir}/pages/layout.haml", "")
      File.write("#{dir}/pages/blog/layout.haml", "")
      File.write("#{dir}/pages/blog/post/page.haml", "")
      File.write("#{dir}/pages/docs/page.haml", "")

      routes = Klenod::Build::PageDiscovery.new(source_dir: dir).call.routes
      routes_by_path = routes.to_h { |route| [route.path, route] }

      assert_equal(
        [
          Klenod::Build::ModuleId.new("pages/layout.haml", nil),
          Klenod::Build::ModuleId.new("pages/blog/layout.haml", nil)
        ],
        routes_by_path.fetch("/blog/post").layout_module_ids
      )
      assert_equal(
        [Klenod::Build::ModuleId.new("pages/layout.haml", nil)],
        routes_by_path.fetch("/docs").layout_module_ids
      )
    end
  end

  def test_route_without_layout_has_empty_layout_module_ids
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/about")
      File.write("#{dir}/pages/about/page.haml", "")

      route = Klenod::Build::PageDiscovery.new(source_dir: dir).call.routes.fetch(0)

      assert_equal([], route.layout_module_ids)
    end
  end

  def test_missing_pages_directory_returns_no_routes
    Dir.mktmpdir do |dir|
      routes = Klenod::Build::PageDiscovery.new(source_dir: dir).call.routes

      assert_equal([], routes)
    end
  end

  def test_raises_for_ambiguous_page_route_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.rb", "")
      File.write("#{dir}/pages/page.haml", "")

      error =
        assert_raises(Klenod::Build::ResolveError) do
          Klenod::Build::PageDiscovery.new(source_dir: dir).call
        end

      assert_includes(error.message, "Ambiguous page route /")
      assert_includes(error.message, "pages/page.rb")
      assert_includes(error.message, "pages/page.haml")
    end
  end

  private

  def segment_values(route)
    route.segments.map { |segment| [segment.name.to_sym, segment.kind, segment.param_name, segment.path_part] }
  end
end
