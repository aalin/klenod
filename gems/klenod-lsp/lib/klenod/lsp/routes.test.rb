# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "__test__/support"

class Klenod::LSP::Routes::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def test_describes_pages_handlers_layouts_and_special_views
    with_routed_app do |workspace|
      routes = workspace.routes

      assert_equal(["Route /docs"], routes.descriptions(module_id("pages/docs/+page.haml")))
      assert_equal(["Route /api"], routes.descriptions(module_id("pages/api/+route.rb")))
      assert_equal(["Layout for 2 routes"], routes.descriptions(module_id("pages/+layout.haml")), "handler routes have no layouts")
      assert_equal(["Not found view for /"], routes.descriptions(module_id("pages/+not-found.haml")))
      assert_empty(routes.descriptions(module_id("components/Details.haml")))
    end
  end

  def test_lenses_lead_with_the_route_and_manifest_follows_file_changes
    with_routed_app do |workspace, dir|
      index = fixture_index(workspace)
      language = Klenod::LSP::Languages::Haml.new
      page_id = module_id("pages/docs/+page.haml")

      lenses = language.code_lenses(workspace.analyze(page_id, "%h1 Docs\n"), workspace, index)
      assert_equal(["Route /docs", "No references"], lenses.map { |lens| lens.command.title })

      FileUtils.mkdir_p("#{dir}/pages/docs/api")
      File.write("#{dir}/pages/docs/api/+page.haml", "%h1 API\n")
      assert_equal(["Route /docs"], workspace.routes.descriptions(page_id), "cached until invalidated")

      workspace.routes.invalidate
      assert_equal(["Layout for 3 routes"], workspace.routes.descriptions(module_id("pages/+layout.haml")))
    end
  end

  def test_hover_markdown_describes_routes_layouts_and_special_views
    with_routed_app do |workspace, dir|
      FileUtils.mkdir_p("#{dir}/pages/docs/[slug]")
      File.write("#{dir}/pages/docs/[slug]/+page.haml", "%h1 Doc\n")
      File.write("#{dir}/pages/docs/[slug]/+route.rb", "def GET(request)\nend\n")
      routes = workspace.routes

      page = routes.hover_markdown(module_id("pages/docs/[slug]/+page.haml"))
      assert_includes(page, "**Route** `/docs/:slug` · `pages/docs/[slug]`")
      assert_includes(page, "Params: `slug` (dynamic)")
      assert_includes(page, "Page: `pages/docs/[slug]/+page.haml`")
      assert_includes(page, "Handler: `pages/docs/[slug]/+route.rb`")
      assert_includes(page, "Layouts: `pages/+layout.haml`")

      layout = routes.hover_markdown(module_id("pages/+layout.haml"))
      assert_includes(layout, "**Layout** for 3 routes: `/`, `/docs`, `/docs/:slug`")

      assert_includes(routes.hover_markdown(module_id("pages/+not-found.haml")), "**Not found view** for `/`")
      assert_nil(routes.hover_markdown(module_id("components/Details.haml")))

      language = Klenod::LSP::Languages::Haml.new
      analysis = workspace.analyze(module_id("pages/docs/+page.haml"), "%h1 Docs\n%p More\n")
      hover = language.hover(analysis, position(0, 3), workspace)
      assert_includes(hover.contents.value, "**Route** `/docs`")
      assert_nil(language.hover(analysis, position(1, 3), workspace), "only the first line describes the route")
    end
  end

  def test_without_a_router_plugin_nothing_is_described
    assert_empty(fixture_workspace.routes.descriptions(module_id("pages/Page.haml")))
  end

  private

  def with_routed_app
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      FileUtils.mkdir_p("#{dir}/pages/docs")
      FileUtils.mkdir_p("#{dir}/pages/api")
      File.write("#{dir}/pages/+layout.haml", "= $children\n")
      File.write("#{dir}/pages/+page.haml", "%h1 Home\n")
      File.write("#{dir}/pages/+not-found.haml", "%h1 Missing\n")
      File.write("#{dir}/pages/docs/+page.haml", "%h1 Docs\n")
      File.write("#{dir}/pages/api/+route.rb", "def GET(request)\nend\n")
      workspace = fixture_workspace(source_dir: dir, extra_plugins: [Klenod::Build::Plugins::RouterPlugin.new(pages_dir: "pages")])

      yield workspace, dir
    end
  end
end
