# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/runtime"
require_relative "../context"

class Klenod::Build::Plugins::RouterPlugin::Test < Minitest::Test
  RouterPlugin = Klenod::Build::Plugins::RouterPlugin

  class RouteBase
  end

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
      FileUtils.mkdir_p("#{dir}/pages/feed/(.)photo")
      FileUtils.mkdir_p("#{dir}/pages/feed/(..)profile")
      FileUtils.mkdir_p("#{dir}/pages/feed/(...)login")
      File.write("#{dir}/pages/blog/[slug]/page.haml", "")
      File.write("#{dir}/pages/docs/[...parts]/page.haml", "")
      File.write("#{dir}/pages/shop/[[...filters]]/page.haml", "")
      File.write("#{dir}/pages/(marketing)/about/page.haml", "")
      File.write("#{dir}/pages/dashboard/@modal/settings/page.haml", "")
      File.write("#{dir}/pages/feed/(.)photo/page.haml", "")
      File.write("#{dir}/pages/feed/(..)profile/page.haml", "")
      File.write("#{dir}/pages/feed/(...)login/page.haml", "")

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
      assert_equal(:intercept_current, routes_by_path.fetch("/feed/photo").segments.fetch(1).kind)
      assert_equal("photo", routes_by_path.fetch("/feed/photo").segments.fetch(1).path_part)
      assert_equal(:intercept_parent, routes_by_path.fetch("/profile").segments.fetch(1).kind)
      assert_equal("profile", routes_by_path.fetch("/profile").segments.fetch(1).path_part)
      assert_equal(:intercept_root, routes_by_path.fetch("/login").segments.fetch(1).kind)
      assert_equal("login", routes_by_path.fetch("/login").segments.fetch(1).path_part)
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

  def test_discovers_special_views_with_their_own_layouts
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/demo")
      File.write("#{dir}/pages/layout.rb", "NAME = :root_layout\n")
      File.write("#{dir}/pages/demo/layout.rb", "NAME = :demo_layout\n")
      File.write("#{dir}/pages/not-found.rb", "NAME = :root_not_found\n")
      File.write("#{dir}/pages/demo/not-found.rb", "NAME = :demo_not_found\n")
      File.write("#{dir}/pages/error.rb", "NAME = :root_error\n")
      File.write("#{dir}/pages/demo/page.rb", "NAME = :demo\n")

      manifest = RouterPlugin.new.discover(source_dir: dir)
      special_views = manifest.special_views.to_h { |view| [[view.kind, view.path], view] }

      assert_equal(["pages/demo/page.rb"], manifest.routes.map(&:module_id).map(&:to_s))
      assert_equal(
        ["pages/demo/page.rb", "pages/error.rb", "pages/not-found.rb", "pages/demo/not-found.rb"],
        manifest.entrypoints
      )
      assert_equal(["pages/layout.rb"], special_views.fetch([:error, "/"]).layout_module_ids.map(&:to_s))
      assert_equal(["pages/layout.rb", "pages/demo/layout.rb"], special_views.fetch([:not_found, "/demo"]).layout_module_ids.map(&:to_s))
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

      assert_includes(error.message, "Ambiguous route /")
      assert_includes(error.message, "pages/page.rb")
      assert_includes(error.message, "pages/page.haml")
    end
  end

  def test_raises_for_ambiguous_special_view_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/error.rb", "")
      File.write("#{dir}/pages/error.haml", "")

      error =
        assert_raises(Klenod::Build::ResolveError) do
          RouterPlugin.new.discover(source_dir: dir)
        end

      assert_includes(error.message, "Ambiguous error route /")
      assert_includes(error.message, "pages/error.rb")
      assert_includes(error.message, "pages/error.haml")
    end
  end

  def test_discovers_page_and_route_handler_in_same_directory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/api")
      File.write("#{dir}/pages/api/page.rb", "NAME = :page\n")
      File.write("#{dir}/pages/api/route.rb", "def GET(_req)\n  :handler\nend\n")

      route = RouterPlugin.new.discover(source_dir: dir).fetch("/api")

      assert_equal(:page_and_handler, route.kind)
      assert_equal(Klenod::Build::ModuleId.new("pages/api/page.rb", nil), route.page_module_id)
      assert_equal(Klenod::Build::ModuleId.new("pages/api/route.rb", nil), route.handler_module_id)
      assert_equal(Klenod::Build::ModuleId.new("pages/api/page.rb", nil), route.module_id)
      assert_equal(["pages/api/page.rb", "pages/api/route.rb"], RouterPlugin.new.discover(source_dir: dir).entrypoints)
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

  def test_virtual_router_matches_closest_not_found_view
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/demo/[section]")
      File.write("#{dir}/pages/not-found.rb", "NAME = :root_not_found\n")
      File.write("#{dir}/pages/demo/[section]/not-found.rb", "NAME = :section_not_found\n")

      router = router_for(dir, mode: :development)
      match = router.not_found("/demo/assets/missing")

      assert_nil(router.match("/demo/assets/missing"))
      assert_equal(:section_not_found, match.page::NAME)
      assert_equal(404, match.status)
      assert_equal({section: "assets"}, match.params)
      assert_equal({}, match.slots)
      assert_equal("pages/demo/[section]/not-found.rb", match.route.module_id)
    end
  end

  def test_virtual_router_matches_error_view_with_view_layouts
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/demo/foobar")
      File.write("#{dir}/pages/layout.rb", "NAME = :root_layout\n")
      File.write("#{dir}/pages/demo/layout.rb", "NAME = :demo_layout\n")
      File.write("#{dir}/pages/error.rb", "NAME = :root_error\n")
      File.write("#{dir}/pages/demo/foobar/page.rb", "NAME = :page\n")

      match = router_for(dir, mode: :development).error("/demo/foobar")

      assert_equal(:root_error, match.page::NAME)
      assert_equal(500, match.status)
      assert_equal([:root_layout], match.layouts.map { |layout| layout::NAME })
      assert_equal(["pages/layout.rb"], match.route.layout_module_ids)
    end
  end

  def test_virtual_router_matches_route_handlers
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/api/[id]")
      File.write(
        "#{dir}/pages/api/[id]/route.rb",
        <<~RUBY
          def GET(_req, _res)
            "api"
          end
        RUBY
      )

      router = router_for(dir, mode: :development)
      match = router.match("/api/123")
      handler = match.handler

      assert_nil(match.page)
      assert_equal({id: "123"}, match.params)
      assert_equal(RouteBase, handler.superclass)
      assert_equal("api", handler.new.GET(nil, nil))
    end
  end

  def test_virtual_router_matches_page_and_route_handler_for_same_path
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/api")
      File.write("#{dir}/pages/api/page.rb", "NAME = :page\n")
      File.write(
        "#{dir}/pages/api/route.rb",
        <<~RUBY
          def GET(_req)
            :handler
          end
        RUBY
      )

      match = router_for(dir, mode: :development).match("/api")

      assert_equal(:page, match.page::NAME)
      assert_equal(RouteBase, match.handler.superclass)
      assert_equal(:handler, match.handler.new.GET(nil))
      assert_equal(:page_and_handler, match.route.kind)
      assert_equal("pages/api/page.rb", match.route.page_module_id)
      assert_equal("pages/api/route.rb", match.route.handler_module_id)
    end
  end

  def test_route_handlers_default_to_regular_classes_without_configured_base
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/api")
      File.write("#{dir}/pages/api/route.rb", "def POST(_req, _res)\n  :ok\nend\n")

      router = router_for(dir, mode: :development, plugin: RouterPlugin.new)
      handler = router.match("/api").handler

      assert_equal(Object, handler.superclass)
      assert_equal(:ok, handler.new.POST(nil, nil))
    end
  end

  def test_route_handlers_rewrite_imports_and_preserve_source_maps
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/api")
      File.write("#{dir}/dep.rb", "VALUE = 42\n")
      File.write(
        "#{dir}/pages/api/route.rb",
        <<~RUBY
          Dep = import("/dep")
          def GET(_req, _res)
            Dep::VALUE
          end
        RUBY
      )

      context = router_context(dir, mode: :development)
      handler = context.entry("virtual:router").exports::Default.match("/api").handler
      record = context.graph.records.fetch(Klenod::Build::ModuleId.new("pages/api/route.rb", nil))
      generated_line = record.transformed_source.lines.find_index { |line| line.include?("Dep::VALUE") } + 1

      assert_equal(42, handler.new.GET(nil, nil))
      assert_includes(record.transformed_source, "class Route < #{self.class.name}::RouteBase")
      assert_includes(record.transformed_source, "__klenod_import__")
      assert_equal(3, record.source_map.find_original_line_no(generated_line))
    end
  end

  def test_virtual_router_prefers_static_route_over_dynamic_route
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog")
      FileUtils.mkdir_p("#{dir}/pages/[slug]")
      File.write("#{dir}/pages/blog/page.rb", "NAME = :blog\n")
      File.write("#{dir}/pages/[slug]/page.rb", "NAME = :dynamic\n")

      router = router_for(dir, mode: :development)

      assert_equal(:blog, router.match("/blog").page::NAME)
      assert_equal(:dynamic, router.match("/about").page::NAME)
      assert_equal({slug: "about"}, router.match("/about").params)
    end
  end

  def test_virtual_router_prefers_dynamic_route_over_catch_all_route
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog/[id]")
      FileUtils.mkdir_p("#{dir}/pages/blog/[...slug]")
      File.write("#{dir}/pages/blog/[id]/page.rb", "NAME = :dynamic\n")
      File.write("#{dir}/pages/blog/[...slug]/page.rb", "NAME = :catch_all\n")

      router = router_for(dir, mode: :development)

      assert_equal(:dynamic, router.match("/blog/123").page::NAME)
      assert_equal({id: "123"}, router.match("/blog/123").params)
      assert_equal(:catch_all, router.match("/blog/2026/07/09").page::NAME)
      assert_equal({slug: ["2026", "07", "09"]}, router.match("/blog/2026/07/09").params)
    end
  end

  def test_virtual_router_prefers_concrete_route_over_optional_catch_all_route
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/docs")
      FileUtils.mkdir_p("#{dir}/pages/docs/[[...slug]]")
      File.write("#{dir}/pages/docs/page.rb", "NAME = :docs\n")
      File.write("#{dir}/pages/docs/[[...slug]]/page.rb", "NAME = :optional\n")

      router = router_for(dir, mode: :development)

      assert_equal(:docs, router.match("/docs").page::NAME)
      assert_equal(:optional, router.match("/docs/a/b").page::NAME)
      assert_equal({slug: ["a", "b"]}, router.match("/docs/a/b").params)
    end
  end

  def test_virtual_router_matches_parallel_slots_with_matching_primary_route
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/dashboard/@modal/settings")
      FileUtils.mkdir_p("#{dir}/pages/dashboard/@sidebar")
      FileUtils.mkdir_p("#{dir}/pages/dashboard/settings")
      File.write("#{dir}/pages/dashboard/layout.rb", "NAME = :dashboard_layout\n")
      File.write("#{dir}/pages/dashboard/page.rb", "NAME = :dashboard\n")
      File.write("#{dir}/pages/dashboard/@modal/page.rb", "NAME = :modal_home\n")
      File.write("#{dir}/pages/dashboard/@modal/settings/page.rb", "NAME = :settings\n")
      File.write("#{dir}/pages/dashboard/@sidebar/page.rb", "NAME = :sidebar\n")
      File.write("#{dir}/pages/dashboard/settings/page.rb", "NAME = :settings_page\n")

      router = router_for(dir, mode: :development)
      dashboard = router.match("/dashboard")
      settings = router.match("/dashboard/settings")

      assert_equal(:dashboard, dashboard.page::NAME)
      assert_equal("/dashboard", dashboard.route.path)
      assert_equal([:modal, :sidebar], dashboard.slots.keys.sort)
      assert_equal(:modal_home, dashboard.slots.fetch(:modal).page::NAME)
      assert_equal(:sidebar, dashboard.slots.fetch(:sidebar).page::NAME)
      assert_equal(:settings_page, settings.page::NAME)
      assert_equal("/dashboard/settings", settings.route.path)
      assert_equal([:modal], settings.slots.keys)
      assert_equal(:settings, settings.slots.fetch(:modal).page::NAME)
      assert_equal("pages/dashboard/layout.rb", settings.slots.fetch(:modal).layout_module_id)
    end
  end

  def test_virtual_router_does_not_match_slot_only_url_without_primary_route
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/dashboard/@modal/settings")
      File.write("#{dir}/pages/dashboard/layout.rb", "NAME = :dashboard_layout\n")
      File.write("#{dir}/pages/dashboard/page.rb", "NAME = :dashboard\n")
      File.write("#{dir}/pages/dashboard/@modal/settings/page.rb", "NAME = :settings\n")

      router = router_for(dir, mode: :development)

      assert_nil(router.match("/dashboard/settings"))
    end
  end

  def test_virtual_router_exposes_structural_route_tree
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog/[slug]")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      File.write("#{dir}/pages/blog/[slug]/page.rb", "NAME = :blog\n")

      tree = router_for(dir, mode: :development).tree
      blog = tree.children.find { |child| child.segment.name == "blog" }
      slug = blog.children.fetch(0)

      assert(tree.root?)
      assert(tree.leaf?)
      assert_equal("/", tree.path)
      assert_equal("pages/page.rb", tree.route.module_id)
      assert_equal("blog", blog.segment.name)
      assert_equal(:static, blog.segment.kind)
      assert_equal("/blog", blog.path)
      refute(blog.leaf?)
      assert_equal("[slug]", slug.segment.name)
      assert_equal(:dynamic, slug.segment.kind)
      assert_equal("/blog/:slug", slug.path)
      assert_equal("pages/blog/[slug]/page.rb", slug.route.module_id)
    end
  end

  def test_virtual_router_tree_preserves_groups_parallel_slots_and_layout_metadata
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/(marketing)/dashboard/@modal/settings")
      File.write("#{dir}/pages/layout.rb", "NAME = :root_layout\n")
      File.write("#{dir}/pages/(marketing)/layout.rb", "NAME = :marketing_layout\n")
      File.write("#{dir}/pages/(marketing)/dashboard/@modal/settings/page.rb", "NAME = :settings\n")

      tree = router_for(dir, mode: :development).tree
      group = tree.children.fetch(0)
      dashboard = group.children.fetch(0)
      slot = dashboard.children.fetch(0)
      settings = slot.children.fetch(0)

      assert_equal("(marketing)", group.segment.name)
      assert_equal(:group, group.segment.kind)
      assert_equal("/", group.path)
      assert_equal("dashboard", dashboard.segment.name)
      assert_equal("/dashboard", dashboard.path)
      assert_equal("@modal", slot.segment.name)
      assert_equal(:parallel, slot.segment.kind)
      assert_equal("modal", slot.segment.param_name)
      assert_equal("/dashboard", slot.path)
      assert_same(slot, dashboard.slots.fetch(:modal))
      assert_equal("settings", settings.segment.name)
      assert_equal("/dashboard/settings", settings.path)
      assert_equal("pages/(marketing)/dashboard/@modal/settings/page.rb", settings.route.module_id)
      assert_equal(["pages/layout.rb", "pages/(marketing)/layout.rb"], settings.route.layout_module_ids)
    end
  end

  def test_virtual_router_tree_exposes_multiple_parallel_slots
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/dashboard/@modal/settings")
      FileUtils.mkdir_p("#{dir}/pages/dashboard/@sidebar/nav")
      File.write("#{dir}/pages/dashboard/page.rb", "NAME = :dashboard\n")
      File.write("#{dir}/pages/dashboard/@modal/settings/page.rb", "NAME = :settings\n")
      File.write("#{dir}/pages/dashboard/@sidebar/nav/page.rb", "NAME = :nav\n")

      tree = router_for(dir, mode: :development).tree
      dashboard = tree.children.fetch(0)

      assert_equal([:modal, :sidebar], dashboard.slots.keys.sort)
      assert_equal("@modal", dashboard.slots.fetch(:modal).segment.name)
      assert_equal("@sidebar", dashboard.slots.fetch(:sidebar).segment.name)
      assert_equal("pages/dashboard/@modal/settings/page.rb", dashboard.slots.fetch(:modal).children.fetch(0).route.module_id)
      assert_equal("pages/dashboard/@sidebar/nav/page.rb", dashboard.slots.fetch(:sidebar).children.fetch(0).route.module_id)
    end
  end

  def test_virtual_router_matches_and_preserves_intercepted_route_segments
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/feed/(.)photo")
      FileUtils.mkdir_p("#{dir}/pages/feed/(..)profile")
      FileUtils.mkdir_p("#{dir}/pages/feed/(...)login")
      File.write("#{dir}/pages/feed/(.)photo/page.rb", "NAME = :photo\n")
      File.write("#{dir}/pages/feed/(..)profile/page.rb", "NAME = :profile\n")
      File.write("#{dir}/pages/feed/(...)login/page.rb", "NAME = :login\n")

      router = router_for(dir, mode: :development)
      feed = router.tree.children.fetch(0)
      photo = feed.children.find { |child| child.segment.name == "(.)photo" }
      profile = feed.children.find { |child| child.segment.name == "(..)profile" }
      login = feed.children.find { |child| child.segment.name == "(...)login" }

      assert_equal(:photo, router.match("/feed/photo").page::NAME)
      assert_equal(:profile, router.match("/profile").page::NAME)
      assert_equal(:login, router.match("/login").page::NAME)
      assert_equal(:intercept_current, photo.segment.kind)
      assert_equal("/feed/photo", photo.path)
      assert_equal(:intercept_parent, profile.segment.kind)
      assert_equal("/profile", profile.path)
      assert_equal(:intercept_root, login.segment.kind)
      assert_equal("/login", login.path)
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
      router_record = context.evaluate("virtual:router")
      router = context.exports(router_record)::Default

      assert_includes(router_record.transformed_source, "__klenod_lazy_import__")
      assert_equal(["virtual:router.rb"], context.graph.records.keys.map(&:to_s))

      assert_equal(:about, router.match("/about").page::NAME)
      assert_includes(context.graph.records.keys.map(&:to_s), "pages/about/page.rb")
      refute_includes(context.graph.records.keys.map(&:to_s), "pages/page.rb")
    end
  end

  def test_development_router_does_not_parse_unmatched_lazy_haml_page_on_startup
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/broken")
      File.write("#{dir}/pages/page.haml", "%h1 Home\n")
      File.write("#{dir}/pages/broken/page.haml", "= @columns.map do |column| }\n  %th= column\n")

      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          mode: :development,
          plugins: [
            RouterPlugin.new(route_base_class: "#{self.class.name}::RouteBase"),
            Klenod::Build::Plugins::RubyPlugin.new,
            Klenod::Build::Plugins::HamlPlugin.new(factory: "Object")
          ]
        )
      router_record = context.evaluate("virtual:router")
      router = context.exports(router_record)::Default

      assert_includes(router_record.transformed_source, "__klenod_lazy_import__")
      assert_equal(["virtual:router.rb"], context.graph.records.keys.map(&:to_s))

      assert(router.match("/"))
      assert_equal(["virtual:router.rb"], context.graph.records.keys.map(&:to_s))

      router.match("/").page
      assert_includes(context.graph.records.keys.map(&:to_s), "pages/page.haml")
      refute_includes(context.graph.records.keys.map(&:to_s), "pages/broken/page.haml")

      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        router.match("/broken").page
      end
    end
  end

  def test_companion_css_change_collects_lazy_router_page
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/blog/[slug]")
      css_path = "#{dir}/pages/blog/[slug]/page.css"
      File.write("#{dir}/pages/blog/[slug]/page.haml", "%h1 Blog\n")

      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          mode: :development,
          plugins: [
            RouterPlugin.new(route_base_class: "#{self.class.name}::RouteBase"),
            Klenod::Build::Plugins::RubyPlugin.new,
            Klenod::Build::Plugins::HamlPlugin.new,
            Klenod::Build::Plugins::CssPlugin.new
          ]
        )
      router_record = context.evaluate("virtual:router")

      assert_equal(["virtual:router.rb"], context.graph.records.keys.map(&:to_s))

      File.write(css_path, "h1 { color: red; }\n")
      result = context.invalidate_paths([css_path])
      css_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("pages/blog/[slug]/page.css", nil))

      assert_equal(["pages/blog/[slug]/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["virtual:router.rb"], result.reevaluated_module_ids.map(&:to_s))
      assert_match(%r{\A/assets/pages_blog_slug_page_css\.[a-f0-9]{16}\.css\z}, css_record.assets.first.output_path)
      assert_includes(context.graph.records.fetch(router_record.id).resolved_dependencies.map(&:module_id), Klenod::Build::ModuleId.new("pages/blog/[slug]/page.haml", nil))
    end
  end

  def test_build_mode_router_keeps_route_imports_lazy
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/about")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      File.write("#{dir}/pages/about/page.rb", "NAME = :about\n")

      context = router_context(dir, mode: :build)
      router_record = context.evaluate("virtual:router")

      assert_includes(router_record.transformed_source, "__klenod_lazy_import__")
      refute_includes(router_record.transformed_source, "__klenod_import__(\"")
      assert_equal(["virtual:router.rb"], context.graph.records.keys.map(&:to_s))
    end
  end

  def test_development_router_uses_lazy_imports_for_special_views
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/not-found.rb", "NAME = :not_found\n")

      context = router_context(dir, mode: :development)
      router_record = context.evaluate("virtual:router")
      router = context.exports(router_record)::Default

      assert_includes(router_record.transformed_source, "__klenod_lazy_import__")
      assert_equal(["virtual:router.rb"], context.graph.records.keys.map(&:to_s))

      assert_equal(:not_found, router.not_found("/missing").page::NAME)
      assert_includes(context.graph.records.keys.map(&:to_s), "pages/not-found.rb")
    end
  end

  def test_virtual_router_records_page_and_layout_watched_patterns
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")

      context = router_context(dir, mode: :development)
      record = context.evaluate("virtual:router")

      expected =
        [
          ["pages/**/error.rb", :router_error],
          ["pages/**/error.haml", :router_error],
          ["pages/**/layout.rb", :router_layout],
          ["pages/**/layout.haml", :router_layout],
          ["pages/**/not-found.rb", :router_not_found],
          ["pages/**/not-found.haml", :router_not_found],
          ["pages/**/page.rb", :router_page],
          ["pages/**/page.haml", :router_page],
          ["pages/**/route.rb", :router_route]
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

  def test_bundle_loads_special_views
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/not-found.rb", "NAME = :not_found\n")
      File.write("#{dir}/pages/error.rb", "NAME = :error\n")
      output = "#{dir}/bundle.dump"
      context = router_context(dir, mode: :build)

      bundle = context.build(entrypoints: ["virtual:router"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      router = loaded.exports("virtual:router")::Default

      assert_includes(bundle.modules.keys, "pages/not-found.rb")
      assert_includes(bundle.modules.keys, "pages/error.rb")
      assert_equal(:not_found, router.not_found("/missing").page::NAME)
      assert_equal(:error, router.error("/missing").page::NAME)
    end
  end

  def test_bundle_loads_hybrid_page_and_route_handler
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/api")
      File.write("#{dir}/pages/api/page.rb", "NAME = :page\n")
      File.write("#{dir}/pages/api/route.rb", "def GET(_req)\n  :handler\nend\n")
      output = "#{dir}/bundle.dump"
      context = router_context(dir, mode: :build)

      bundle = context.build(entrypoints: ["virtual:router"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      match = loaded.exports("virtual:router")::Default.match("/api")

      assert_includes(bundle.modules.keys, "pages/api/page.rb")
      assert_includes(bundle.modules.keys, "pages/api/route.rb")
      assert_equal(:page, match.page::NAME)
      assert_equal(:handler, match.handler.new.GET(nil))
    end
  end

  def test_bundle_allows_pages_to_import_router
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/routes")
      File.write("#{dir}/pages/page.rb", "NAME = :root\n")
      File.write(
        "#{dir}/pages/routes/page.rb",
        <<~RUBY
          Router = import("virtual:router")
          NAME = :routes
          ROUTE_COUNT = Router::Default.routes.length
        RUBY
      )
      output = "#{dir}/bundle.dump"
      context = router_context(dir, mode: :build)

      bundle = context.build(entrypoints: ["virtual:router"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      router = loaded.exports("virtual:router")::Default
      routes_page = router.match("/routes").page

      assert_includes(bundle.modules.keys, "pages/routes/page.rb")
      assert_equal(:routes, routes_page::NAME)
      assert_equal(2, routes_page::ROUTE_COUNT)
    end
  end

  private

  def router_context(dir, mode:, plugin: nil)
    Klenod::Build::Context.new(
      source_dir: dir,
      mode: mode,
      plugins: [
        plugin || RouterPlugin.new(route_base_class: "#{self.class.name}::RouteBase"),
        Klenod::Build::Plugins::RubyPlugin.new
      ]
    )
  end

  def router_for(dir, mode:, plugin: nil)
    context = router_context(dir, mode: mode, plugin: plugin)
    context.entry("virtual:router").exports::Default
  end

  def segment_values(route)
    route.segments.map { |segment| [segment.name.to_sym, segment.kind, segment.param_name, segment.path_part] }
  end
end
