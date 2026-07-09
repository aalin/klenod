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

      routes = Klenod::Build::PageDiscovery.new(source_dir: dir).call

      assert_equal(
        [
          ["/", Klenod::Build::ModuleId.new("pages/page.haml", nil)],
          ["/blog", Klenod::Build::ModuleId.new("pages/blog/page.rb", nil)]
        ],
        routes.map { |route| [route.path, route.module_id] }
      )
    end
  end

  def test_context_exposes_page_routes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/app/about")
      File.write("#{dir}/app/about/page.haml", "")

      context = Klenod::Build::Context.new(source_dir: dir)
      routes = context.page_routes(pages_dir: "app")

      assert_equal("/about", routes.fetch(0).path)
      assert_equal(Klenod::Build::ModuleId.new("app/about/page.haml", nil), routes.fetch(0).module_id)
    end
  end

  def test_missing_pages_directory_returns_no_routes
    Dir.mktmpdir do |dir|
      routes = Klenod::Build::PageDiscovery.new(source_dir: dir).call

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
end
