# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

require "bundler/setup"
require "klenod"
require_relative "lib/framework"
require_relative "lib/server/app"
require_relative "lib/server/errors"

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
    assert_includes(html, "Build Ruby modules like a modern frontend graph")
    assert_includes(html, "Transform source files")
    assert_includes(html, "Explore demos")
    assert_includes(html, "/assets/pages_layout_css")
    assert_includes(html, "/assets/pages_page_css")
    paths = stylesheet_paths(html)
    assert_stylesheet_indexes_present(html)
    assert_stylesheet_order(paths, "pages_root_css", "pages_layout_css", "pages_page_css", "components_Button_css")
    refute(paths.any? { |path| path.include?("pages_demo_dashboard") })
    refute(paths.any? { |path| path.include?("pages_demo_assets") })
  end

  def test_example_app_links_route_scoped_css_assets
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/demo/dashboard"), context)
    html = body.join
    paths = stylesheet_paths(html)

    assert_equal(200, status)
    assert_stylesheet_indexes_present(html)
    assert(paths.any? { |path| path.include?("pages_demo_dashboard_page_css") })
    assert(paths.any? { |path| path.include?("components_MetricCard_css") })
    refute(paths.any? { |path| path.include?("pages_page_css") })
    refute(paths.any? { |path| path.include?("pages_demo_assets_page_css") })
    assert_stylesheet_order(
      paths,
      "pages_root_css",
      "pages_layout_css",
      "pages_demo_layout_css",
      "pages_demo_dashboard_layout_css",
      "pages_demo_dashboard_page_css",
      "components_MetricCard_css"
    )
  end

  def test_example_app_renders_nested_route_through_layout
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body = entry.call(request("/demo/blog/graph"), context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "<body")
    assert_includes(html, "Klenod example")
    assert_includes(html, "Building a lazy module graph")
    assert_includes(html, "Ruby modules loaded through a dependency graph")
    assert_includes(html, "Blog posts")
    assert_includes(html, "Generated assets as imports")
    assert_includes(html, "href=\"/demo/blog/routing\"")
  end

  def test_example_app_renders_route_gallery_pages
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    assert_route_includes(entry, context, "/demo", "Explore Klenod features")
    assert_route_includes(entry, context, "/demo/blog", "Blog posts loaded from data files")
    assert_route_includes(entry, context, "/demo/blog/assets", "Generated assets as imports")
    assert_route_includes(entry, context, "/demo/data", "Imported from a plain text file.")
    assert_route_includes(entry, context, "/demo/hybrid", "Hybrid page and route handler")
    assert_route_includes(entry, context, "/demo/translations", "Render localized component text")
    assert_route_includes(entry, context, "/demo/docs/guides/routing", "Path parts: guides / routing")
    assert_route_includes(entry, context, "/demo/shop", "No filters selected")
    assert_route_includes(entry, context, "/demo/shop/sale/red", "Filters: sale, red")
    assert_route_includes(entry, context, "/demo/assets", "Images become generated browser assets")
    assert_route_includes(entry, context, "/demo/assets", "CSS url()")
    assert_route_includes(entry, context, "/about", "inside a route group")
    assert_route_includes(entry, context, "/demo/dashboard", "Dashboard showcase")
    assert_route_includes(entry, context, "/demo/dashboard", "Showcase routes")
    assert_route_includes(entry, context, "/demo/dashboard", "Showcase notice")
    assert_route_includes(entry, context, "/demo/dashboard", "command=\"show-modal\"")
    assert_route_includes(entry, context, "/demo/dashboard", "commandfor=\"dashboard-modal\"")
    assert_route_includes(entry, context, "/demo/dashboard/settings", "Dashboard settings")
    assert_route_includes(entry, context, "/demo/dashboard/settings", "Unsaved settings")
    assert_route_includes(entry, context, "/demo/feed/photo", "Photo intercept")
    assert_route_includes(entry, context, "/profile", "Profile intercept")
    assert_route_includes(entry, context, "/login", "Login intercept")
  end

  def test_example_app_resolves_translations_from_accept_language
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body =
      entry.call(
        HeaderRequest["GET", "/demo/translations", HeaderList.new([["Accept-Language", "sv-SE,sv;q=0.9,en-US;q=0.8"]])],
        context
      )
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_equal("Accept-Language, Cookie", headers.fetch("vary"))
    assert_includes(html, "Rendera lokaliserad komponenttext")
    assert_includes(html, "<article lang=\"sv-SE\"")
    assert_includes(html, "Vald locale")
    assert_includes(html, "Haml-komponenter som PageHeader")
    assert_includes(html, "2 locales är tillgängliga.")
    assert_includes(html, "sv-SE")
    refute_includes(html, "Render localized component text")
  end

  def test_example_app_falls_back_to_available_locale_with_same_language
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body =
      entry.call(
        HeaderRequest["GET", "/demo/translations", HeaderList.new([["Accept-Language", "sv-FI;q=0.9,en-US;q=0.8"]])],
        context
      )
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Rendera lokaliserad komponenttext")
    assert_includes(html, "<article lang=\"sv-SE\"")
    assert_includes(html, "sv-SE")
  end

  def test_example_app_falls_back_to_default_translation_locale
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body =
      entry.call(
        HeaderRequest["GET", "/demo/translations", HeaderList.new([["Accept-Language", "fr-FR,fr;q=0.9"]])],
        context
      )
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Render localized component text")
    assert_includes(html, "Resolved locale")
    assert_includes(html, "en-US")
  end

  def test_example_app_locale_cookie_overrides_accept_language
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body =
      entry.call(
        HeaderRequest[
          "GET",
          "/demo/translations",
          HeaderList.new([
            ["Accept-Language", "en-US,en;q=0.9"],
            ["Cookie", "#{Example::LOCALE_COOKIE}=sv-SE"]
          ])
        ],
        context
      )
    html = body.join

    assert_equal(200, status)
    assert_equal("Accept-Language, Cookie", headers.fetch("vary"))
    assert_includes(html, "Rendera lokaliserad komponenttext")
    assert_includes(html, "Locale-cookie")
    assert_includes(html, "sv-SE")
  end

  def test_example_app_sets_locale_cookie_from_form_post
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    _status, response_headers, body = entry.call(BodyRequest["GET", "/demo/translations", HeaderList.new([]), nil], context)
    cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    csrf_token = csrf_token_from(body.join)
    form = URI.encode_www_form("csrf_token" => csrf_token, "locale" => "sv-SE")
    status, headers, body =
      entry.call(
        BodyRequest[
          "POST",
          "/demo/translations/locale",
          HeaderList.new([
            ["Content-Type", "application/x-www-form-urlencoded"],
            ["Cookie", cookie],
            ["Referer", "/demo/translations"]
          ]),
          form
        ],
        context
      )

    assert_equal(302, status)
    assert_equal("/demo/translations", headers.fetch("location"))
    assert_empty(body)
    assert_includes(headers.fetch("set-cookie"), "#{Example::LOCALE_COOKIE}=sv-SE")
  end

  def test_example_app_clears_locale_cookie_from_form_post
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    existing_cookie = "#{Example::LOCALE_COOKIE}=sv-SE"
    _status, response_headers, body =
      entry.call(BodyRequest["GET", "/demo/translations", HeaderList.new([["Cookie", existing_cookie]]), nil], context)
    session_cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    csrf_token = csrf_token_from(body.join)
    form = URI.encode_www_form("csrf_token" => csrf_token, "locale" => "")
    status, headers, body =
      entry.call(
        BodyRequest[
          "POST",
          "/demo/translations/locale",
          HeaderList.new([
            ["Content-Type", "application/x-www-form-urlencoded"],
            ["Cookie", "#{existing_cookie}; #{session_cookie}"],
            ["Referer", "/demo/translations"]
          ]),
          form
        ],
        context
      )

    assert_equal(302, status)
    assert_equal("/demo/translations", headers.fetch("location"))
    assert_empty(body)
    assert_includes(headers.fetch("set-cookie"), "#{Example::LOCALE_COOKIE}=")
    assert_includes(headers.fetch("set-cookie"), "Max-Age=0")
  end

  def test_example_routes_utility_prints_route_table
    stdout, stderr, status =
      Open3.capture3(
        {
          "NO_COLOR" => "1",
          "KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS" => "1"
        },
        RbConfig.ruby,
        "bin/routes",
        chdir: __dir__
      )

    assert(status.success?, stderr)
    assert_includes(stdout, "METHOD")
    assert_includes(stdout, "PATH")
    assert_includes(stdout, "SOURCE")
    assert_includes(stdout, "GET      /demo/blog/:slug")
    assert_includes(stdout, "pages/demo/blog/[slug]/page.haml")
    assert_includes(stdout, "POST     /demo/forms/submit")
    assert_includes(stdout, "pages/demo/forms/submit/route.rb")
    assert_includes(stdout, "GET      /demo/hybrid")
    assert_includes(stdout, "OPTIONS  /demo/hybrid")
    assert_includes(stdout, "Route tree")
    assert_includes(stdout, "GET /demo/blog/:slug (page)")
    assert_includes(stdout, "layout pages/demo/blog/[slug]/layout.haml")
    assert_includes(stdout, "page pages/demo/blog/[slug]/page.haml")
    assert_includes(stdout, "slot @modal pages/demo/dashboard/@modal/page.haml")
    assert_includes(stdout, "slot @sidebar pages/demo/dashboard/@sidebar/page.haml")
    assert_includes(stdout, "POST /demo/forms/submit (handler)")
    assert_includes(stdout, "handler pages/demo/forms/submit/route.rb:3")
    assert_includes(stdout, "GET,PUT,OPTIONS /demo/hybrid (page+handler)")
    assert_includes(stdout, "handler pages/demo/hybrid/route.rb:1")
    assert_includes(stdout, "└─ layout pages/layout.haml\n   page pages/feed/(.)photo/page.haml")
    assert_includes(stdout, "└─ layout pages/layout.haml\n   └─ layout pages/demo/layout.haml\n      └─ layout pages/demo/dashboard/layout.haml\n         page pages/demo/dashboard/settings/page.haml")
  end

  def test_example_app_renders_router_tree_metadata
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/demo/routing"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Route examples")
    assert_includes(html, "Parallel slots: modal, sidebar")
    assert_includes(html, "(.)photo:intercept_current")
    assert_includes(html, "(..)profile:intercept_parent")
    assert_includes(html, "(...)login:intercept_root")
  end

  def test_example_app_renders_not_found_page
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body = entry.call(request("/demo/missing"), context)
    html = body.join

    assert_equal(404, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Page not found")
    assert_includes(html, "No route matched /demo/missing.")
    assert_includes(html, "Browse the demo routes")
  end

  def test_example_app_renders_not_found_page_for_not_found_error
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, headers, body = entry.call(request("/demo/not-found-error"), context)
    html = body.join

    assert_equal(404, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Page not found")
    assert_includes(html, "No route matched /demo/not-found-error.")
    refute_includes(html, "Something went wrong")
  end

  def test_example_app_renders_error_page_with_error_view_layout
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status = headers = body = nil
    _stdout, stderr = capture_io do
      status, headers, body = entry.call(request("/demo/error"), context)
    end
    html = body.join
    paths = stylesheet_paths(html)

    assert_equal(500, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Something went wrong")
    assert_includes(html, "Rendering /demo/error raised RuntimeError.")
    assert_includes(html, "Demo render failure")
    assert_includes(html, "RuntimeError")
    assert_includes(html, "Backtrace")
    assert_includes(stderr, "RuntimeError: Demo render failure")
    assert_includes(stderr, "pages/demo/error/page.haml")
    assert(paths.any? { |path| path.include?("pages_layout_css") })
    refute(paths.any? { |path| path.include?("pages_demo_layout_css") })
  end

  def test_example_server_formats_haml_parse_errors_without_backtrace
    error = Klenod::Build::Plugins::HamlPlugin::ParseError.new(
      Klenod::Build::Plugins::HamlPlugin::RubyParseError.new("Could not build Ruby block", line: 2),
      source: "%table\n  = @columns.map { |column| )\n    %th= column\n",
      module_id: Klenod::Build::ModuleId.new("components/DataTable.haml", nil)
    )
    formatted = Example::ServerErrors.format_exception(error, nil)

    assert_includes(formatted, "components/DataTable.haml:2: Haml parse error")
    assert_includes(formatted, "> 2 |   = @columns.map { |column| )")
    refute_includes(formatted, "Backtrace:")
  end

  def test_example_server_returns_pretty_html_error_response_for_html_requests
    server = Example::DevServer.allocate
    error = RuntimeError.new("<broken>")
    status, headers, body =
      server.send(
        :error_response_for,
        HeaderRequest["GET", "/demo/data", HeaderList.new([["Accept", "text/html"]])],
        error,
        "\e[31mRuntimeError: <broken>\e[0m"
      )
    html = body.join

    assert_equal(500, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Development error")
    assert_includes(html, "Request /demo/data raised RuntimeError.")
    assert_includes(html, "&lt;broken&gt;")
    refute_includes(html, "\e[31m")
  end

  def test_example_server_formats_haml_parse_error_html_as_sections
    server = Example::DevServer.allocate
    server.instance_variable_set(:@config, example_config)
    error = Klenod::Build::Plugins::HamlPlugin::ParseError.new(
      Klenod::Build::Plugins::HamlPlugin::RubyParseError.new(
        "Could not build Ruby block from Haml script: \"@columns.map do |column| }\"\n\nErrors:\n  Unmatched `}', missing `{' ?\n  Unmatched keyword, missing `end' ?",
        line: 2
      ),
      source: "%table\n  = @columns.map do |column| }\n    %th= column\n",
      module_id: Klenod::Build::ModuleId.new("components/DataTable.haml", nil)
    )
    status, _headers, body =
      server.send(
        :error_response_for,
        HeaderRequest["GET", "/demo/data", HeaderList.new([["Accept", "text/html"]])],
        error,
        Example::ServerErrors.format_exception(error, nil)
      )
    html = body.join

    assert_equal(500, status)
    assert_includes(html, "src/components/DataTable.haml:2: Haml parse error")
    assert_includes(html, "Could not build Ruby block from Haml script:")
    assert_includes(html, "<li>Unmatched `}&#39;, missing `{&#39; ?</li>")
    assert_includes(html, "<h2>Source</h2>")
    assert_includes(html, "&gt; 2 |   = @columns.map do |column| }")
    refute_includes(html, "<h2>Backtrace</h2>")
    refute_includes(html, "ERROR  components/DataTable.haml")
  end

  def test_example_server_keeps_plain_error_response_for_non_html_requests
    server = Example::DevServer.allocate
    status, headers, body =
      server.send(
        :error_response_for,
        HeaderRequest["GET", "/demo/data", HeaderList.new([["Accept", "application/json"]])],
        RuntimeError.new("broken"),
        "\e[31mRuntimeError: broken\e[0m"
      )

    assert_equal(500, status)
    assert_equal("text/plain; charset=utf-8", headers.fetch("content-type"))
    assert_equal(["RuntimeError: broken", "\n"], body)
  end

  def test_example_server_tracks_logged_update_errors
    server = Example::DevServer.allocate
    error = RuntimeError.new("broken module")

    refute(server.send(:logged_error?, error))
    server.send(:remember_logged_error, error)
    assert(server.send(:logged_error?, error))
    server.send(:clear_logged_errors)
    refute(server.send(:logged_error?, error))
  end

  def test_example_server_suppresses_recent_logged_update_errors
    server = Example::DevServer.allocate
    error = RuntimeError.new("broken module")

    server.send(:remember_logged_error, error, logged_at: 10.0)

    assert(server.send(:recently_logged_error?, RuntimeError.new("broken module"), now: 11.0))
    refute(server.send(:recently_logged_error?, RuntimeError.new("broken module"), now: 13.0))
  end

  def test_example_server_logs_repeated_errors_after_interval
    server = Example::DevServer.allocate
    error = RuntimeError.new("broken module")

    server.send(:remember_logged_error, error, logged_at: -Example::DevServer::ERROR_LOG_REPEAT_INTERVAL)

    _stdout, stderr = capture_io { server.send(:log_error_unless_recent, RuntimeError.new("broken module"), "formatted error") }

    assert_equal("formatted error\n", stderr)
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

  def test_example_app_dispatches_hybrid_route_by_accept_header
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    html_status, html_headers, html_body =
      entry.call(HeaderRequest["GET", "/demo/hybrid", HeaderList.new([["Accept", "text/html"]])], context)
    json_status, json_headers, json_body =
      entry.call(HeaderRequest["GET", "/demo/hybrid", HeaderList.new([["Accept", "application/json"]])], context)

    assert_equal(200, html_status)
    assert_equal("text/html; charset=utf-8", html_headers.fetch("content-type"))
    assert_includes(html_body.join, "Hybrid page and route handler")

    assert_equal(200, json_status)
    assert_equal("application/json; charset=utf-8", json_headers.fetch("content-type"))
    assert_equal("Accept", json_headers.fetch("vary"))
    assert_equal({"type" => "hybrid", "path" => "/demo/hybrid", "request" => "api"}, JSON.parse(json_body.join))
  end

  def test_example_app_dispatches_hybrid_route_non_page_methods_to_handler
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    status, headers, body =
      entry.call(HeaderRequest["OPTIONS", "/demo/hybrid", HeaderList.new([["Accept", "text/html"]])], context)

    assert_equal(200, status)
    assert_equal("application/json; charset=utf-8", headers.fetch("content-type"))
    assert_equal({"type" => "hybrid", "path" => "/demo/hybrid", "method" => "OPTIONS"}, JSON.parse(body.join))
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
          "/demo/forms?tag=ruby&tag=klenod&user[name]=Andreas&filters[]=fresh&filters[]=smoked&items[][name]=Coffee&items[][name]=Tea"
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
    request = Example::Request.from(BodyRequest["POST", "/demo/forms/submit", HeaderList.new([]), body])

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

  def test_example_i18n_uses_fiber_local_request_context
    translations = {
      "en-US" => {"title" => "Hello"},
      "sv-SE" => {"title" => "Hej"}
    }
    english = Example::Request.from(HeaderRequest["GET", "/", HeaderList.new([["Accept-Language", "en-US"]])])
    swedish = Example::Request.from(HeaderRequest["GET", "/", HeaderList.new([["Accept-Language", "sv-SE"]])])

    Example::Context.with(request: english) do
      other = Fiber.new do
        Example::Context.with(request: swedish) do
          Example::I18n.t(translations, :title)
        end
      end

      assert_equal("Hej", other.resume)
      assert_equal("Hello", Example::I18n.t(translations, :title))
    end
  end

  def test_example_i18n_supports_configurable_default_locale
    translations = {
      "en-US" => {"title" => "Hello"},
      "sv-SE" => {"title" => "Hej"}
    }
    previous = Example::I18n.default_locale
    Example::I18n.default_locale = "sv-SE"

    assert_equal("sv-SE", Example::I18n.resolve_locale(translations, request: nil))
    assert_equal("Hej", Example::I18n.t(translations, :title, locale: nil))
  ensure
    Example::I18n.default_locale = previous
  end

  def test_example_i18n_interpolates_values_and_pluralizes_counts
    translations = {
      "en-US" => {
        "greeting" => "Hello %{name}",
        "items" => {
          "zero" => "No items",
          "one" => "One item",
          "other" => "%{count} items"
        }
      }
    }

    assert_equal("Hello Andreas", Example::I18n.t(translations, :greeting, name: "Andreas"))
    assert_equal("No items", Example::I18n.t(translations, :items, count: 0))
    assert_equal("One item", Example::I18n.t(translations, :items, count: 1))
    assert_equal("3 items", Example::I18n.t(translations, :items, count: 3))
  end

  def test_example_i18n_warns_once_for_missing_interpolation_values
    translations = {
      "en-US" => {
        "greeting" => "Hello %{name}"
      }
    }

    previous_no_color = ENV.delete("NO_COLOR")
    begin
      _stdout, stderr = capture_io do
        assert_equal("Hello %{name}", Example::I18n.t(translations, :greeting, source: "components/Greeting.haml"))
        assert_equal("Hello %{name}", Example::I18n.t(translations, :greeting, source: "components/Greeting.haml"))
      end
    ensure
      ENV["NO_COLOR"] = previous_no_color if previous_no_color
    end

    assert_equal(1, stderr.scan("Missing interpolation").length)
    assert_includes(stderr, "Missing interpolation :name for \"greeting\" in en-US in components/Greeting.haml")
    assert_includes(stderr, "\e[1;30;43m WARNING \e[0m")
  end

  def test_example_i18n_warning_format_respects_no_color
    with_env("NO_COLOR" => "1") do
      assert_equal("WARNING Missing interpolation :name", Example::I18n.format_warning("Missing interpolation :name"))
    end
  end

  def test_example_i18n_warns_once_for_missing_translations
    translations = {
      "en-US" => {"title" => "Hello"},
      "sv-SE" => {}
    }
    request = Example::Request.from(HeaderRequest["GET", "/", HeaderList.new([["Accept-Language", "sv-SE"]])])

    _stdout, stderr = capture_io do
      Example::Context.with(request: request) do
        assert_equal("Hello", Example::I18n.t(translations, :title, source: "components/Greeting.haml"))
        assert_equal("Hello", Example::I18n.t(translations, :title, source: "components/Greeting.haml"))
      end
    end

    assert_equal(1, stderr.scan("Missing translation").length)
    assert_includes(stderr, "Missing translation \"title\" for sv-SE in components/Greeting.haml; falling back to en-US")
  end

  def test_example_app_stores_form_values_in_encrypted_session_cookie
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, response_headers, body = entry.call(BodyRequest["GET", "/demo/forms", HeaderList.new([]), nil], context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", response_headers.fetch("content-type"))
    assert_includes(html, "Session-backed form")

    cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    csrf_token = csrf_token_from(html)
    headers = HeaderList.new([
      ["Content-Type", "application/x-www-form-urlencoded"],
      ["Cookie", cookie]
    ])
    form = URI.encode_www_form("csrf_token" => csrf_token, "name" => "Andreas")
    status, response_headers, body = entry.call(BodyRequest["POST", "/demo/forms/submit", headers, form], context)

    assert_equal(302, status)
    assert_equal("/demo/forms", response_headers.fetch("location"))
    assert_empty(body)

    cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    status, headers, body = entry.call(BodyRequest["GET", "/demo/forms", HeaderList.new([["Cookie", cookie]]), nil], context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Session-backed form")
    assert_includes(html, "Welcome back, Andreas.")
    assert_includes(html, "Clear session")

    csrf_token = csrf_token_from(html)
    headers = HeaderList.new([
      ["Content-Type", "application/x-www-form-urlencoded"],
      ["Cookie", cookie]
    ])
    form = URI.encode_www_form("csrf_token" => csrf_token)
    status, response_headers, body = entry.call(BodyRequest["POST", "/demo/forms/clear", headers, form], context)

    assert_equal(302, status)
    assert_equal("/demo/forms", response_headers.fetch("location"))
    assert_includes(response_headers.fetch("set-cookie"), "#{Example::SESSION_COOKIE}=")
    assert_includes(response_headers.fetch("set-cookie"), "Max-Age=0")
    assert_empty(body)

    expired_cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    status, headers, body = entry.call(BodyRequest["GET", "/demo/forms", HeaderList.new([["Cookie", expired_cookie]]), nil], context)
    html = body.join

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(html, "Submit the form to store your name in an encrypted session cookie.")
    refute_includes(html, "Welcome back, Andreas.")
  end

  def test_example_app_rejects_invalid_csrf_tokens
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    _status, response_headers, _body = entry.call(BodyRequest["GET", "/demo/forms", HeaderList.new([]), nil], context)
    cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    headers = HeaderList.new([
      ["Content-Type", "application/x-www-form-urlencoded"],
      ["Cookie", cookie]
    ])
    form = URI.encode_www_form("csrf_token" => "nope", "name" => "Andreas")
    status, headers, body = entry.call(BodyRequest["POST", "/demo/forms/submit", headers, form], context)

    assert_equal(403, status)
    assert_equal("text/plain; charset=utf-8", headers.fetch("content-type"))
    assert_equal("Invalid CSRF token\n", body.join)
  end

  def test_example_request_closes_readable_bodies_after_parsing_forms
    body = ReadableBody.new("name=And", "reas")
    request = Example::Request.from(BodyRequest["POST", "/demo/forms/submit", HeaderList.new([]), body])

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
    status, _headers, body = entry.call(request("/demo/assets"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "srcset=")
    assert(context.assets_for("pages/demo/assets/coffee.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("pages/demo/assets/sailing-boat.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("pages/demo/assets/vegetables.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
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
    with_env("KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS" => "1") do
      Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
    end
  end

  def with_env(values)
    previous = values.to_h { |key, value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end

  def request(path, method: "GET")
    Request[method, path]
  end

  def csrf_token_from(html)
    html.match(/<input[^>]*name="csrf_token"[^>]*value="([^"]+)"/)[1]
  end

  def stylesheet_paths(html)
    html.scan(%r{<link rel="stylesheet" href="([^"]+)"}).flatten
  end

  def stylesheet_indexes(html)
    html.scan(%r{<link rel="stylesheet" href="[^"]+" data-index="(\d+)"}).flatten.map(&:to_i)
  end

  def assert_stylesheet_indexes_present(html)
    paths = stylesheet_paths(html)
    indexes = stylesheet_indexes(html)

    assert_equal(paths.length, indexes.length)
    assert_equal(indexes.sort, indexes)
  end

  def assert_stylesheet_order(paths, *names)
    indexes =
      names.map do |name|
        paths.find_index { |path| path.include?(name) } || flunk("Missing stylesheet #{name} in #{paths.inspect}")
      end

    assert_equal(indexes.sort, indexes, "Expected #{names.inspect} to appear in order")
  end

  def assert_route_includes(entry, context, path, text)
    status, headers, body = entry.call(request(path), context)

    assert_equal(200, status)
    assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
    assert_includes(body.join, text)
  end
end
