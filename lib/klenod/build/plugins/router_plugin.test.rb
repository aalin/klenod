# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../../runtime"
require_relative "../context"

class Klenod::Build::Plugins::RouterPlugin::Test < Minitest::Test
  RouterPlugin = Klenod::Build::Plugins::RouterPlugin

  def test_discovers_root_nested_routes_and_layouts
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog")
      FileUtils.mkdir_p("#{dir}/pages/components")
      File.write("#{dir}/pages/page.haml", "")
      File.write("#{dir}/pages/blog/page.rb", "")
      File.write("#{dir}/pages/layout.haml", "")
      File.write("#{dir}/pages/components/Card.haml", "")

      manifest = RouterPlugin.new.discover(source_dir: dir)
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

      routes_by_path = RouterPlugin.new.discover(source_dir: dir).routes.to_h { |route| [route.path, route] }

      assert_equal([:static, :dynamic], routes_by_path.fetch("/blog/:slug").segments.map(&:kind))
      assert_equal("slug", routes_by_path.fetch("/blog/:slug").segments.fetch(1).param_name)
      assert_equal([RouterPlugin::RouteParam.new("slug", :dynamic)], routes_by_path.fetch("/blog/:slug").params)
      assert_equal("/docs/*parts", routes_by_path.fetch("/docs/*parts").path)
      assert_equal(:catch_all, routes_by_path.fetch("/docs/*parts").segments.fetch(1).kind)
      assert_equal([RouterPlugin::RouteParam.new("parts", :catch_all)], routes_by_path.fetch("/docs/*parts").params)
      assert_equal("/shop", routes_by_path.fetch("/shop").path)
      assert_equal(:optional_catch_all, routes_by_path.fetch("/shop").segments.fetch(1).kind)
      assert_equal([RouterPlugin::RouteParam.new("filters", :optional_catch_all)], routes_by_path.fetch("/shop").params)
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

      routes_by_path = RouterPlugin.new.discover(source_dir: dir).routes.to_h { |route| [route.path, route] }

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

  def test_missing_pages_directory_returns_no_routes
    Dir.mktmpdir do |dir|
      assert_equal([], RouterPlugin.new.discover(source_dir: dir).routes)
    end
  end

  def test_raises_for_ambiguous_page_route_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.rb", "")
      File.write("#{dir}/pages/page.haml", "")

      error =
        assert_raises(Klenod::Build::ResolveError) do
          RouterPlugin.new.discover(source_dir: dir)
        end

      assert_includes(error.message, "Ambiguous page route /")
      assert_includes(error.message, "pages/page.rb")
      assert_includes(error.message, "pages/page.haml")
    end
  end

  def test_virtual_router_matches_routes_and_params
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog/[slug]")
      FileUtils.mkdir_p("#{dir}/pages/docs/[...parts]")
      FileUtils.mkdir_p("#{dir}/pages/shop/[[...filters]]")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      File.write("#{dir}/pages/blog/[slug]/page.rb", "NAME = :blog\n")
      File.write("#{dir}/pages/docs/[...parts]/page.rb", "NAME = :docs\n")
      File.write("#{dir}/pages/shop/[[...filters]]/page.rb", "NAME = :shop\n")

      router = router_for(dir, mode: :development)

      assert_equal(:root, router.match("/")&.page::NAME)
      assert_equal(:blog, router.match("/blog/hello").page::NAME)
      assert_equal({slug: "hello"}, router.match("/blog/hello").params)
      assert_equal(:docs, router.match("/docs/a/b").page::NAME)
      assert_equal({parts: ["a", "b"]}, router.match("/docs/a/b").params)
      assert_equal(:shop, router.match("/shop").page::NAME)
      assert_equal({filters: []}, router.match("/shop").params)
      assert_equal({filters: ["sale", "red"]}, router.match("/shop/sale/red").params)
      assert_nil(router.match("/missing"))
    end
  end

  def test_virtual_router_exposes_layouts_from_outermost_to_nearest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog/post")
      File.write("#{dir}/pages/layout.rb", "NAME = :root_layout\n")
      File.write("#{dir}/pages/blog/layout.rb", "NAME = :blog_layout\n")
      File.write("#{dir}/pages/blog/post/page.rb", "NAME = :post\n")

      match = router_for(dir, mode: :development).match("/blog/post")

      assert_equal(:post, match.page::NAME)
      assert_equal([:root_layout, :blog_layout], match.layouts.map { |layout| layout::NAME })
      assert_equal(["pages/layout.rb", "pages/blog/layout.rb"], match.route.layout_module_ids)
    end
  end

  def test_development_router_uses_lazy_imports_and_defers_page_loading
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/about")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      File.write("#{dir}/pages/about/page.rb", "NAME = :about\n")

      context = router_context(dir, mode: :development)
      router_record = context.load("virtual:router")
      router = context.exports(router_record)::Default

      assert_includes(router_record.transformed_source, "__klenod_lazy_import__")
      assert_equal(["virtual:router.rb"], context.graph.records.keys.map(&:to_s))

      assert_equal(:about, router.match("/about").page::NAME)
      assert_includes(context.graph.records.keys.map(&:to_s), "pages/about/page.rb")
      refute_includes(context.graph.records.keys.map(&:to_s), "pages/page.rb")
    end
  end

  def test_build_mode_router_uses_eager_imports
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/about")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      File.write("#{dir}/pages/about/page.rb", "NAME = :about\n")

      context = router_context(dir, mode: :build)
      router_record = context.load("virtual:router")

      assert_includes(router_record.transformed_source, "__klenod_import__")
      assert_includes(context.graph.records.keys.map(&:to_s), "pages/page.rb")
      assert_includes(context.graph.records.keys.map(&:to_s), "pages/about/page.rb")
    end
  end

  def test_virtual_router_records_page_and_layout_watched_patterns
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")

      context = router_context(dir, mode: :development)
      record = context.load("virtual:router")

      expected =
        [
          ["pages/**/layout.rb", :router_layout],
          ["pages/**/layout.haml", :router_layout],
          ["pages/**/page.rb", :router_page],
          ["pages/**/page.haml", :router_page]
        ].sort_by { |glob, kind| [glob, kind.to_s] }

      assert_equal(
        expected,
        record.watched_patterns.map { |pattern| [pattern.glob, pattern.kind] }.sort_by { |glob, kind| [glob, kind.to_s] }
      )
    end
  end

  def test_virtual_router_updates_when_page_file_is_added
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/about")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")

      context = router_context(dir, mode: :development)
      router = context.entry("virtual:router").exports::Default

      assert_nil(router.match("/about"))

      about_path = "#{dir}/pages/about/page.rb"
      File.write(about_path, "NAME = :about\n")
      result = context.invalidate_paths([about_path])
      router = context.exports("virtual:router.rb")::Default

      assert_includes(result.reloaded_module_ids.map(&:to_s), "virtual:router.rb")
      assert_equal(:about, router.match("/about").page::NAME)
    end
  end

  def test_virtual_router_updates_when_page_file_is_removed
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/about")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      about_path = "#{dir}/pages/about/page.rb"
      File.write(about_path, "NAME = :about\n")

      context = router_context(dir, mode: :development)
      router = context.entry("virtual:router").exports::Default

      assert_equal(:about, router.match("/about").page::NAME)

      File.delete(about_path)
      result = context.invalidate_paths([], removed_paths: [about_path])
      router = context.exports("virtual:router.rb")::Default

      assert_includes(result.reloaded_module_ids.map(&:to_s), "virtual:router.rb")
      assert_nil(router.match("/about"))
    end
  end

  def test_bundle_loads_router_and_all_pages
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/about")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      File.write("#{dir}/pages/about/page.rb", "NAME = :about\n")
      output = "#{dir}/bundle.dump"
      context = router_context(dir, mode: :build)

      bundle = context.build(entrypoints: ["virtual:router"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      router = loaded.exports("virtual:router")::Default

      assert_equal(["virtual:router"], bundle.entrypoints.keys)
      assert_equal(:root, router.match("/").page::NAME)
      assert_equal(:about, router.match("/about").page::NAME)
    end
  end

  private

  def router_context(dir, mode:)
    Klenod::Build::Context.new(
      source_dir: dir,
      mode: mode,
      plugins: [
        Klenod::Build::Plugins::RubyPlugin.new,
        RouterPlugin.new
      ]
    )
  end

  def router_for(dir, mode:)
    context = router_context(dir, mode: mode)
    context.entry("virtual:router").exports::Default
  end

  def segment_values(route)
    route.segments.map { |segment| [segment.name.to_sym, segment.kind, segment.param_name, segment.path_part] }
  end
end
