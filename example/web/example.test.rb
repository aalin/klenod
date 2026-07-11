# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../../lib/klenod"
require_relative "framework"

class Klenod::ExampleTest < Minitest::Test
  Request = Data.define(:method, :path)
  HeaderRequest = Data.define(:method, :path, :headers)
  BodyRequest = Data.define(:method, :path, :headers, :body)

  class HeaderList
    def initialize(headers)
      @headers = headers
    end

    def each(&)
      @headers.each(&)
    end
  end

  class ReadableBody
    attr_reader :closed

    def initialize(*chunks)
      @chunks = chunks
      @closed = false
    end

    def read
      @chunks.shift
    end

    def close
      @closed = true
    end
  end

  def test_example_app_loads_renders_and_emits_assets
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
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
    assert_includes(html, "Current request path: /")
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
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body = entry.call(request("/blog/hello"), context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "<body")
    assert_includes(html, "Klenod example")
    assert_includes(html, "Blog post: hello")
    assert_includes(html, "Ruby modules loaded through a dependency graph")
  end

  def test_example_app_renders_route_gallery_pages
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    assert_route_includes(entry, context, "/docs/guides/routing", "Path parts: guides / routing")
    assert_route_includes(entry, context, "/shop", "No filters selected")
    assert_route_includes(entry, context, "/shop/sale/red", "Filters: sale, red")
    assert_route_includes(entry, context, "/gallery", "Image gallery")
    assert_route_includes(entry, context, "/gallery", "Coffee imported from a routed Haml page.")
    assert_route_includes(entry, context, "/about", "inside a route group")
    assert_route_includes(entry, context, "/dashboard", "Harbor dispatch dashboard")
    assert_route_includes(entry, context, "/dashboard", "Control room")
    assert_route_includes(entry, context, "/dashboard", "Shift handover")
    assert_route_includes(entry, context, "/dashboard", "command=\"show-modal\"")
    assert_route_includes(entry, context, "/dashboard", "commandfor=\"dashboard-modal\"")
    assert_route_includes(entry, context, "/dashboard/settings", "Dispatch preferences")
    assert_route_includes(entry, context, "/dashboard/settings", "Unsaved policy changes")
    assert_route_includes(entry, context, "/feed/photo", "Photo intercept")
    assert_route_includes(entry, context, "/profile", "Profile intercept")
    assert_route_includes(entry, context, "/login", "Login intercept")
  end

  def test_example_app_renders_router_tree_metadata
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/routes"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Router gallery")
    assert_includes(html, "Parallel slots: modal, sidebar")
    assert_includes(html, "(.)photo:intercept_current")
    assert_includes(html, "(..)profile:intercept_parent")
    assert_includes(html, "(...)login:intercept_root")
  end

  def test_example_app_renders_route_handler_response
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body = entry.call(request("/api/status?via=test"), context)

    assert_equal(200, status)
    assert_equal("application/json; charset=utf-8", headers.fetch("content-type"))
    assert_equal(
      {
        "status" => "ok",
        "service" => "klenod",
        "method" => "GET",
        "path" => "/api/status",
        "query" => {"via" => "test"}
      },
      JSON.parse(body.join)
    )
  end

  def test_example_request_copies_protocol_style_headers
    headers = HeaderList.new([["Accept", "application/json"]])
    request = Example::Request.from(HeaderRequest["GET", "/api/status", headers])

    assert_equal({"accept" => "application/json"}, request.headers)
  end

  def test_example_request_parses_nested_query_params
    request =
      Example::Request.from(
        Request[
          "GET",
          "/forms?tag=ruby&tag=klenod&user[name]=Andreas&filters[]=fresh&filters[]=smoked&items[][name]=Coffee&items[][name]=Tea"
        ]
      )

    assert_equal(
      {
        "tag" => ["ruby", "klenod"],
        "user" => {"name" => "Andreas"},
        "filters" => ["fresh", "smoked"],
        "items" => [
          {"name" => "Coffee"},
          {"name" => "Tea"}
        ]
      },
      request.query
    )
  end

  def test_example_request_parses_nested_form_params
    body = "order[customer][name]=Andreas&order[items][]=coffee&order[items][]=tea"
    request = Example::Request.from(BodyRequest["POST", "/forms/submit", HeaderList.new([]), body])

    assert_equal(
      {
        "order" => {
          "customer" => {"name" => "Andreas"},
          "items" => ["coffee", "tea"]
        }
      },
      request.form
    )
  end

  def test_example_app_stores_form_values_in_encrypted_session_cookie
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    headers = HeaderList.new([["Content-Type", "application/x-www-form-urlencoded"]])
    status, response_headers, body = entry.call(BodyRequest["POST", "/forms/submit", headers, "name=Andreas"], context)

    assert_equal(302, status)
    assert_equal("/forms", response_headers.fetch("location"))
    assert_empty(body)

    cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    status, headers, body = entry.call(BodyRequest["GET", "/forms", HeaderList.new([["Cookie", cookie]]), nil], context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Session-backed form")
    assert_includes(html, "Welcome back, Andreas.")
    assert_includes(html, "Clear session")

    status, response_headers, body = entry.call(BodyRequest["POST", "/forms/clear", HeaderList.new([["Cookie", cookie]]), ""], context)

    assert_equal(302, status)
    assert_equal("/forms", response_headers.fetch("location"))
    assert_includes(response_headers.fetch("set-cookie"), "#{Example::SESSION_COOKIE}=")
    assert_includes(response_headers.fetch("set-cookie"), "Max-Age=0")
    assert_empty(body)

    expired_cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    status, headers, body = entry.call(BodyRequest["GET", "/forms", HeaderList.new([["Cookie", expired_cookie]]), nil], context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Submit the form to store your name in an encrypted session cookie.")
    refute_includes(html, "Welcome back, Andreas.")
  end

  def test_example_request_closes_readable_bodies_after_parsing_forms
    body = ReadableBody.new("name=And", "reas")
    request = Example::Request.from(BodyRequest["POST", "/forms/submit", HeaderList.new([]), body])

    assert_equal({"name" => "Andreas"}, request.form)
    assert_equal(true, body.closed)
  end

  def test_example_app_renders_redirect_response
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body = entry.call(request("/api/redirect"), context)

    assert_equal(302, status)
    assert_equal("/", headers.fetch("location"))
    assert_empty(body)
  end

  def test_example_app_passes_route_params_to_handler_request
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body = entry.call(request("/api/posts/hello-world"), context)

    assert_equal(200, status)
    assert_equal("application/json; charset=utf-8", headers.fetch("content-type"))
    assert_equal(
      {
        "slug" => "hello-world",
        "path" => "/api/posts/hello-world"
      },
      JSON.parse(body.join)
    )
  end

  def test_example_app_emits_gallery_image_variants
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/gallery"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "srcset=")
    assert(context.assets_for("pages/gallery/coffee.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("pages/gallery/sailing-boat.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("pages/gallery/vegetables.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
  end

  def test_example_app_builds_and_loads_runtime_bundle
    config = example_config

    Dir.mktmpdir do |dir|
      output = "#{dir}/klenod.bundle"
      assets_dir = "#{dir}/public"
      context = config.context
      bundle = context.build(entrypoints: config.entrypoints, output: output, assets_dir: assets_dir)
      loaded = Klenod::Runtime.load_bundle(output, source_root: "/app/src")
      page = loaded.exports(config.entrypoints.fetch(0))
      status, _headers, body = page.call(nil, loaded)

      assert_equal(200, status)
      assert_includes(body.join, "<main")
      assert_equal("/app/src/pages/server.rb", page.module_path)
      assert_equal(bundle.assets.keys.sort, loaded.assets.keys.sort)
      loaded.each_asset do |asset|
        disk_path = File.join(assets_dir, asset.output_path.delete_prefix("/"))

        assert(File.exist?(disk_path), "Expected #{disk_path} to exist")
      end
    end
  end

  private

  def example_config
    Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
  end

  def request(path, method: "GET")
    Request[method, path]
  end

  def assert_route_includes(entry, context, path, text)
    status, headers, body = entry.call(request(path), context)

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(body.join, text)
  end
end
