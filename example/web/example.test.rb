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

  class EarlyHintsRequest
    attr_reader :method, :path, :headers, :interim_responses

    def initialize(method, path, headers = HeaderList.new([]))
      @method = method
      @path = path
      @headers = headers
      @interim_responses = []
    end

    def send_interim_response(status, headers)
      @interim_responses << [status, headers]
    end
  end

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

  def test_example_h_builds_descriptors_and_escapes_when_rendering
    node = Example::H[:p, "Fish & chips", title: %("quoted")]

    assert_instance_of(Example::H::Element, node)
    assert_equal(:p, node.tag)
    assert_equal([Example::H::Text["Fish & chips"]], node.children)
    assert_equal(%(<p title="&quot;quoted&quot;">Fish &amp; chips</p>), Example::H.render(node))
  end

  def test_example_h_partitions_component_slots
    component =
      Class.new(Example::Component) do
        def render
          raise "slots leaked into props" if @__props.key?(:slots)

          Example::H[
            :section,
            Example::H[:button, *children[:button]],
            Example::H[:div, *@__props[:children]]
          ]
        end
      end

    node =
      Example::H[
        component,
        Example::H[:span, "Button", slot: "button"],
        Example::H[:p, "Default"]
      ]
    html = Example::H.render(node)

    assert_includes(html, "<button><span>Button</span></button>")
    assert_includes(html, "<div><p>Default</p></div>")
    refute_includes(html, "slot=")
  end

  def test_haml_helper_merges_scoped_and_external_classes
    Dir.mktmpdir do |dir|
      File.write("#{dir}/component.css", "button { color: red; }\n.button { display: block; }\n")
      File.write("#{dir}/component.haml", "%button.button{class: $button_class} Press\n")

      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::HamlPlugin.new(
              component_base_class: "Example::Component",
              factory: "Example::H",
              global_variables: "@__props"
            ),
            Klenod::Build::Plugins::CssPlugin.new
          ]
        )
      record = context.evaluate("component.haml")
      component = context.graph.mods.fetch(record.id).const_get(:Exports)::Default
      rendered = Example::H.render(component.instantiate(button_class: "external").render)

      assert_match(/class="[^"]*\bexternal\b[^"]*"/, rendered)
      assert_match(/class="[^"]*\bcomponent_button\?/, rendered)
      assert_match(/class="[^"]*\bcomponent\.button\?/, rendered)
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
    assert_includes(html, "/assets/routes_layout_css")
    assert_includes(html, "/assets/routes_page_css")
    paths = stylesheet_paths(html)
    assert_stylesheet_indexes_present(html)
    assert_stylesheet_paths_unique(paths)
    assert_linked_stylesheets_do_not_import_linked_stylesheets(context, paths)
    assert_stylesheet_order(paths, "routes_root_css", "routes_layout_css", "routes_page_css", "components_Button_css")
    refute(paths.any? { |path| path.include?("routes_demo_dashboard") })
    refute(paths.any? { |path| path.include?("routes_demo_assets") })
  end

  def test_example_app_uses_system_theme_without_theme_cookie
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    _status, _headers, body = entry.call(request("/"), context)

    assert_includes(body.join, "<html>")
  end

  def test_example_app_renders_explicit_theme_attribute_from_cookie
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    %w[light dark].each do |theme|
      headers = HeaderList.new([["Cookie", "#{Example::THEME_COOKIE}=#{theme}"]])
      _status, _response_headers, body = entry.call(HeaderRequest["GET", "/", headers], context)

      assert_includes(body.join, "<html data-theme=\"#{theme}\">")
    end
  end

  def test_example_app_ignores_invalid_theme_cookie
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    headers = HeaderList.new([["Cookie", "#{Example::THEME_COOKIE}=sepia"]])
    _status, _response_headers, body = entry.call(HeaderRequest["GET", "/", headers], context)

    assert_includes(body.join, "<html>")
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
    assert_stylesheet_paths_unique(paths)
    assert(paths.any? { |path| path.include?("routes_demo_dashboard_page_css") })
    assert(paths.any? { |path| path.include?("components_MetricCard_css") })
    refute(paths.any? { |path| path.include?("routes_page_css") })
    refute(paths.any? { |path| path.include?("routes_demo_assets_page_css") })
    assert_stylesheet_order(
      paths,
      "routes_root_css",
      "routes_layout_css",
      "routes_demo_layout_css",
      "routes_demo_dashboard_layout_css",
      "routes_demo_dashboard_page_css",
      "components_MetricCard_css"
    )
  end

  def test_example_app_sends_early_hints_for_route_stylesheets
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    request = EarlyHintsRequest.new("GET", "/demo/dashboard")

    status, headers, body = entry.call(request, context)
    paths = stylesheet_paths(body.join)
    _early_status, early_headers = request.interim_responses.fetch(0)
    link = early_headers.fetch(0).fetch(1)

    assert_equal(200, status)
    refute_includes(headers.keys, "link")
    assert_equal([[103, [["link", link]]]], request.interim_responses)
    paths.each do |path|
      assert_includes(link, "<#{path}>; rel=preload; as=style")
    end
  end

  def test_example_app_includes_preload_link_header_without_early_hints_support
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    status, headers, body = entry.call(request("/demo/dashboard"), context)
    paths = stylesheet_paths(body.join)
    link = headers.fetch("link")

    assert_equal(200, status)
    paths.each do |path|
      assert_includes(link, "<#{path}>; rel=preload; as=style")
    end
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
    assert_includes(html, "Klenod can collect dependencies without evaluating every module immediately")
    assert_includes(html, "Blog posts")
    assert_includes(html, "Generated assets as imports")
    assert_includes(html, "href=\"/demo/blog/routing\"")
  end

  def test_example_app_renders_route_gallery_pages
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    assert_route_includes(entry, context, "/demo", "Explore Klenod features")
    assert_route_includes(entry, context, "/demo/blog", "Blog posts loaded from Markdown files")
    assert_route_includes(entry, context, "/demo/blog/assets", "Generated assets as imports")
    assert_route_includes(entry, context, "/demo/data", "Imported from a plain text file.")
    assert_route_includes(entry, context, "/demo/hybrid", "Hybrid page and route handler")
    assert_route_includes(entry, context, "/demo/markdown", "Render Markdown through factory calls")
    assert_route_includes(entry, context, "/demo/markdown", "Inline Markdown")
    assert_route_includes(entry, context, "/demo/markdown", "components/markdown/Link")
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

  def test_example_app_localizes_markdown_links
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/sv/demo/markdown"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, %(href="/sv/demo/markdown"))
  end

  def test_example_app_renders_docs_routes_with_scoped_components
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    html_by_path = {}

    _stdout, stderr = capture_io do
      [
        "/docs",
        "/docs/core-concepts",
        "/docs/configuration",
        "/docs/haml-components",
        "/docs/templates",
        "/docs/assets",
        "/docs/plugins",
        "/docs/plugins/RubyPlugin",
        "/docs/plugins/HamlPlugin",
        "/docs/plugins/MarkdownPlugin",
        "/docs/plugins/CssPlugin",
        "/docs/plugins/RouterPlugin",
        "/docs/plugins/Assets",
        "/docs/plugins/DataPlugins",
        "/docs/plugins/IntlPlugin",
        "/docs/plugins/GoogleFontsPlugin"
      ].each do |path|
        status, headers, body = entry.call(request(path), context)

        assert_equal(200, status)
        assert_equal("text/html; charset=utf-8", headers.fetch("content-type"))
        html_by_path[path] = body.join
      end
    end

    assert_empty(stderr)
    assert_includes(html_by_path.fetch("/docs"), "components/DocsLinkCard")
    assert_includes(html_by_path.fetch("/docs"), "Core Concepts")
    assert_includes(html_by_path.fetch("/docs"), "<details")
    assert_includes(html_by_path.fetch("/docs"), "<summary")
    assert_includes(html_by_path.fetch("/docs/templates"), "components/DocsPage")
    assert_includes(html_by_path.fetch("/docs/templates"), "components/DocsSection")
    assert_includes(html_by_path.fetch("/docs/templates"), "components/markdown/Paragraph")
    assert_includes(html_by_path.fetch("/docs/templates"), "components/markdown/InlineCode")
    assert_includes(html_by_path.fetch("/docs/core-concepts"), "Collection Comes First")
    assert_includes(html_by_path.fetch("/docs/configuration"), "Plugin Order")
    assert_includes(html_by_path.fetch("/docs/configuration"), "language-ruby")
    assert_match(%r{components/markdown/InlineCode\.(k|nc|nb|s2)\?}, html_by_path.fetch("/docs/configuration"))
    assert_includes(html_by_path.fetch("/docs/haml-components"), "Scope Boundaries")
    assert_includes(html_by_path.fetch("/docs/haml-components"), "language-haml")
    assert_match(%r{components/markdown/InlineCode\.(k|nt|nc|s2)\?}, html_by_path.fetch("/docs/haml-components"))
    assert_includes(html_by_path.fetch("/docs/assets"), "components/markdown/ListItem")
    assert_includes(html_by_path.fetch("/docs/plugins"), "RubyPlugin")
    assert_includes(html_by_path.fetch("/docs/plugins/HamlPlugin"), "Translation companions use")
    assert_includes(html_by_path.fetch("/docs/plugins/IntlPlugin"), "is absent, Haml still compiles")
    assert_includes(html_by_path.fetch("/docs/plugins/GoogleFontsPlugin"), "cache_path")
    assert_match(/<details(?=[^>]*open)[^>]*>\s*<summary[^>]*>Guides/, html_by_path.fetch("/docs/haml-components"))
    assert_match(/<details(?=[^>]*open)[^>]*>\s*<summary[^>]*>Plugins/, html_by_path.fetch("/docs/plugins/HamlPlugin"))
    refute_includes(html_by_path.fetch("/docs/haml-components"), "{&quot;class&quot;")
    refute_includes(html_by_path.fetch("/docs/templates"), "docs-content p")
  end

  def test_example_app_caches_markdown_syntax_highlighting
    require "rouge"

    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    context.evaluate("components/markdown/InlineCode.haml")
    inline_code = context.exports("components/markdown/InlineCode.haml")::Default
    inline_code.const_get(:HIGHLIGHT_CACHE).clear

    ruby_lexer = Rouge::Lexer.find("ruby")
    original_lex = ruby_lexer.singleton_class.instance_method(:lex)
    lex_count = 0
    ruby_lexer.define_singleton_method(:lex) do |*args, **kwargs, &block|
      lex_count += 1
      original_lex.bind_call(self, *args, **kwargs, &block)
    end

    2.times do
      status, _headers, body = entry.call(request("/docs/getting-started"), context)

      assert_equal(200, status)
      assert_includes(body.join, "language-ruby")
    end

    assert_equal(4, lex_count)
  ensure
    ruby_lexer&.define_singleton_method(:lex, original_lex) if ruby_lexer && original_lex
  end

  def test_example_app_renders_swedish_localized_routes
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/sv/demo/assets"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Bilder blir genererade browser assets")
    assert_includes(html, "popovertarget=\"language-menu\"")
    assert_includes(html, "popovertargetaction=\"toggle\"")
    assert_includes(html, "title=\"Choose language\"")
    language_switcher_css_path =
      stylesheet_paths(html).find { |path| path.include?("components_LanguageSwitcher_css") }
    flunk("Expected LanguageSwitcher stylesheet") unless language_switcher_css_path
    assert_includes(context.asset(language_switcher_css_path).bytes, "language_solid_full")
    assert_includes(html, "href=\"/demo/assets\"")
    assert_includes(html, "href=\"/sv/demo/assets\"")
    assert_includes(html, "href=\"/sv/demo/formular\"")
    assert_includes(html, "href=\"/sv/demo/blogg/graph\"")
    assert_includes(html, "href=\"/sv/demo/butik/sale/red\"")
    assert_route_includes(entry, context, "/sv/dokumentation/haml-komponenter", "Haml Components")
    assert_includes(html, "Standardimport")
    assert_includes(html, "Varianter")
  end

  def test_example_app_keeps_dynamic_values_when_localizing_routes
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/sv-SE/demo/blogg/tillgangar"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Blog post: tillgangar")
    assert_includes(html, "No Markdown post exists for this slug")
    assert_includes(html, "href=\"/sv-SE/demo/blogg/graph\"")
  end

  def test_example_app_renders_translated_overview_pages
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))

    status, _headers, body = entry.call(request("/sv"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Bygg Ruby-moduler som en modern frontendgraf")
    assert_includes(html, "Utforska demos")

    status, _headers, body = entry.call(request("/sv/demo"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Utforska Klenod-funktioner i små routade exempel")
    assert_includes(html, "Importera JSON, YAML, TOML och text")
  end

  def test_example_app_imports_route_translation_files_for_reloading
    config = example_config
    context = config.context

    context.entry(config.entrypoints.fetch(0))
    server_record = context.graph.records.fetch(Klenod::Build::ModuleId.new("entrypoint.rb", nil))
    specifiers = server_record.dependencies.map(&:specifier)

    assert_includes(specifiers, "/routes.intl.en.toml")
    assert_includes(specifiers, "/routes.intl.sv.toml")
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
    assert_includes(stdout, "routes/demo/blog/[slug]/+page.haml")
    assert_includes(stdout, "POST     /demo/forms/submit")
    assert_includes(stdout, "routes/demo/forms/submit/+route.rb")
    assert_includes(stdout, "GET      /demo/hybrid")
    assert_includes(stdout, "OPTIONS  /demo/hybrid")
    assert_includes(stdout, "Route tree")
    assert_includes(stdout, "GET /demo/blog/:slug (page)")
    assert_includes(stdout, "layout routes/demo/blog/[slug]/+layout.haml")
    assert_includes(stdout, "page routes/demo/blog/[slug]/+page.haml")
    assert_includes(stdout, "slot @modal routes/demo/dashboard/@modal/+page.haml")
    assert_includes(stdout, "slot @sidebar routes/demo/dashboard/@sidebar/+page.haml")
    assert_includes(stdout, "POST /demo/forms/submit (handler)")
    assert_includes(stdout, "handler routes/demo/forms/submit/+route.rb:3")
    assert_includes(stdout, "GET,PUT,OPTIONS /demo/hybrid (page+handler)")
    assert_includes(stdout, "handler routes/demo/hybrid/+route.rb:1")
    assert_includes(stdout, "└─ layout routes/+layout.haml\n   page routes/feed/(.)photo/+page.haml")
    assert_includes(stdout, "└─ layout routes/+layout.haml\n   └─ layout routes/demo/+layout.haml\n      └─ layout routes/demo/dashboard/+layout.haml\n         page routes/demo/dashboard/settings/+page.haml")
  end

  def test_example_app_renders_router_tree_metadata
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, _headers, body = entry.call(request("/demo/routing"), context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "Route sitemap")
    assert_includes(html, "Sitemap")
    assert_includes(html, "/demo/blog/:slug")
    assert_includes(html, "demo/blog/[slug]/+page.haml")
    assert_includes(html, "Parallel slots")
    assert_includes(html, "@modal")
    assert_includes(html, "Error boundaries")
    assert_includes(html, "+not-found.haml")
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
    assert_includes(stderr, "routes/demo/error/+page.haml")
    assert(paths.any? { |path| path.include?("routes_layout_css") })
    refute(paths.any? { |path| path.include?("routes_demo_layout_css") })
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
    error_page = Example::DevelopmentErrorPage.new(config: nil, context: nil)
    error = RuntimeError.new("<broken>")
    status, headers, body =
      error_page.response_for(
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
    config = example_config
    error_page = Example::DevelopmentErrorPage.new(config: config, context: config.context)
    error = Klenod::Build::Plugins::HamlPlugin::ParseError.new(
      Klenod::Build::Plugins::HamlPlugin::RubyParseError.new(
        "Could not build Ruby block from Haml script: \"@columns.map do |column| }\"\n\nErrors:\n  Unmatched `}', missing `{' ?\n  Unmatched keyword, missing `end' ?",
        line: 2
      ),
      source: "%table\n  = @columns.map do |column| }\n    %th= column\n",
      module_id: Klenod::Build::ModuleId.new("components/DataTable.haml", nil)
    )
    status, _headers, body =
      error_page.response_for(
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
    error_page = Example::DevelopmentErrorPage.new(config: nil, context: nil)
    status, headers, body =
      error_page.response_for(
        HeaderRequest["GET", "/demo/data", HeaderList.new([["Accept", "application/json"]])],
        RuntimeError.new("broken"),
        "\e[31mRuntimeError: broken\e[0m"
      )

    assert_equal(500, status)
    assert_equal("text/plain; charset=utf-8", headers.fetch("content-type"))
    assert_equal(["RuntimeError: broken", "\n"], body)
  end

  def test_server_runner_serves_assets_before_app
    asset_response = Klenod::Rack::Response.new(200, {"content-type" => "text/css"}, "body {}")
    asset_app = Data.define(:response, :env) do
      def response_for(_path, env = {})
        self.env.merge!(env)
        response
      end
    end.new(asset_response, {})
    app = ->(_request) { raise "app should not be called" }
    runner = Example::ServerRunner.new(port: 9292, asset_app: asset_app, app: app, error_handler: ->(_request, error) { raise error })

    response = nil
    capture_io do
      response = runner.response_for(HeaderRequest["GET", "/assets/app.css", HeaderList.new([["Accept-Encoding", "gzip, br"]])])
    end

    assert_equal(200, response.status)
    assert_equal("text/css", response.headers["content-type"])
    assert_equal("gzip, br", asset_app.env.fetch("HTTP_ACCEPT_ENCODING"))
  end

  def test_server_runner_dispatches_non_asset_requests_to_app
    asset_app = Data.define(:response) do
      def response_for(_path, _env = {}) = response
    end.new(nil)
    app = ->(_request) { [201, {"content-type" => "text/plain"}, ["ok"]] }
    runner = Example::ServerRunner.new(port: 9292, asset_app: asset_app, app: app, error_handler: ->(_request, error) { raise error })

    response = nil
    capture_io do
      response = runner.response_for(HeaderRequest["GET", "/demo", HeaderList.new([])])
    end

    assert_equal(201, response.status)
    assert_equal("text/plain", response.headers["content-type"])
  end

  def test_server_runner_leaves_content_length_to_protocol_http
    asset_response = Klenod::Rack::Response.new(200, {"content-type" => "text/css", "content-length" => "7"}, "body {}")
    asset_app = Data.define(:response) do
      def response_for(_path, _env = {}) = response
    end.new(asset_response)
    runner = Example::ServerRunner.new(port: 9292, asset_app: asset_app, app: ->(_request) { raise "unused" }, error_handler: ->(_request, error) { raise error })

    response = nil
    capture_io do
      response = runner.response_for(HeaderRequest["GET", "/assets/app.css", HeaderList.new([])])
    end

    refute_includes(response.headers, "content-length")
  end

  def test_dev_server_handles_chrome_devtools_probe
    source_dir = "/tmp/klenod_example/src"
    probe = Example::ChromeDevtoolsProbe.new(source_dir: source_dir, uuid: "6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b")
    status, headers, body =
      probe.response_for(HeaderRequest["GET", "/.well-known/appspecific/com.chrome.devtools.json", HeaderList.new([])])
    payload = JSON.parse(body.join)

    assert_equal(200, status)
    assert_equal("application/json; charset=utf-8", headers.fetch("content-type"))
    assert_equal("no-store", headers.fetch("cache-control"))
    assert_equal(source_dir, payload.dig("workspace", "root"))
    assert_equal("6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b", payload.dig("workspace", "uuid"))
  end

  def test_production_server_returns_generic_error_response
    server = Example::ProductionServer.allocate
    status, headers, body = nil
    _stdout, stderr = capture_io do
      status, headers, body = server.send(:error_response_for, RuntimeError.new("secret failure"))
    end

    assert_equal(500, status)
    assert_equal("text/plain; charset=utf-8", headers.fetch("content-type"))
    assert_equal(["Internal server error\n"], body)
    assert_includes(stderr, "RuntimeError")
    assert_includes(stderr, "secret failure")
    refute_includes(body.join, "secret failure")
  end

  def test_example_server_tracks_logged_update_errors
    recent_errors = Example::RecentErrorLog.new
    error = RuntimeError.new("broken module")

    refute(recent_errors.include?(error))
    recent_errors.remember(error)
    assert(recent_errors.include?(error))
    recent_errors.clear
    refute(recent_errors.include?(error))
  end

  def test_example_server_suppresses_recent_logged_update_errors
    recent_errors = Example::RecentErrorLog.new
    error = RuntimeError.new("broken module")

    recent_errors.remember(error, logged_at: 10.0)

    assert(recent_errors.recent?(RuntimeError.new("broken module"), now: 11.0))
    refute(recent_errors.recent?(RuntimeError.new("broken module"), now: 13.0))
  end

  def test_example_server_logs_repeated_errors_after_interval
    recent_errors = Example::RecentErrorLog.new
    error = RuntimeError.new("broken module")

    recent_errors.remember(error, logged_at: -Example::RecentErrorLog::DEFAULT_REPEAT_INTERVAL)

    _stdout, stderr = capture_io { recent_errors.warn_unless_recent(RuntimeError.new("broken module"), "formatted error") }

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
    english = localized_request(locale: "en")
    swedish = localized_request(locale: "sv")

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

  def test_example_localized_routes_use_default_locale_without_prefix
    routes = localized_routes

    assert_equal("/demo/assets", routes.localized_path("/demo/assets", locale: "en"))
    assert_equal("/demo/assets", routes.canonicalize_path("/demo/assets").path)
  end

  def test_example_localized_routes_translate_static_segments
    routes = localized_routes

    assert_equal("/sv/demo/assets", routes.localized_path("/demo/assets", locale: "sv"))
    assert_equal("/demo/assets", routes.canonicalize_path("/sv/demo/assets").path)
  end

  def test_example_h_localizes_local_anchor_hrefs
    request = localized_request(locale: "sv")

    Example::Context.with(request: request, routes: localized_routes) do
      html = Example::H.render(Example::H[:a, "Assets", href: "/demo/assets"])

      assert_includes(html, %(href="/sv/demo/assets"))
    end
  end

  def test_example_h_uses_hreflang_for_local_anchor_hrefs
    request = localized_request(locale: "en")

    Example::Context.with(request: request, routes: localized_routes) do
      html = Example::H.render(Example::H[:a, "Assets", href: "/demo/assets?from=docs#top", hreflang: "sv"])

      assert_includes(html, %(href="/sv/demo/assets?from=docs#top"))
      assert_includes(html, %(hreflang="sv"))
    end
  end

  def test_example_h_canonicalizes_already_localized_anchor_hrefs
    request = localized_request(locale: "sv")

    Example::Context.with(request: request, routes: localized_routes) do
      html = Example::H.render(Example::H[:a, "Assets", href: "/sv/demo/assets"])

      assert_includes(html, %(href="/sv/demo/assets"))
      refute_includes(html, "/sv/sv/")
    end
  end

  def test_example_h_keeps_dynamic_anchor_segments_when_localizing
    request = localized_request(locale: "sv")

    Example::Context.with(request: request, routes: localized_routes) do
      html = Example::H.render(Example::H[:a, "Blog post", href: "/demo/blog/shop"])

      assert_includes(html, %(href="/sv/demo/blogg/shop"))
      refute_includes(html, "/sv/demo/blogg/butik")
    end
  end

  def test_example_h_leaves_non_app_anchor_hrefs_unchanged
    request = localized_request(locale: "sv")

    Example::Context.with(request: request, routes: localized_routes) do
      assert_includes(Example::H.render(Example::H[:a, "External", href: "https://example.com/demo/assets"]), %(href="https://example.com/demo/assets"))
      assert_includes(Example::H.render(Example::H[:a, "Protocol relative", href: "//example.com/demo/assets"]), %(href="//example.com/demo/assets"))
      assert_includes(Example::H.render(Example::H[:a, "Mail", href: "mailto:hello@example.com"]), %(href="mailto:hello@example.com"))
      assert_includes(Example::H.render(Example::H[:a, "Fragment", href: "#intro"]), %(href="#intro"))
      assert_includes(Example::H.render(Example::H[:a, "Asset", href: "/assets/app.css"]), %(href="/assets/app.css"))
    end
  end

  def test_example_localized_routes_use_same_language_fallback
    routes = localized_routes
    localized = routes.canonicalize_path("/sv-SE/demo/assets")

    assert_equal("/sv-SE/demo/assets", routes.localized_path("/demo/assets", locale: "sv-SE"))
    assert_equal("/demo/assets", localized.path)
    assert_equal("sv-SE", localized.locale)
    assert_equal("sv", localized.route_locale)
  end

  def test_example_localized_routes_fall_back_to_canonical_missing_segments
    routes = localized_routes(translations: {"en" => {"segments" => {}}, "sv" => {"segments" => {"demo" => "demo"}}})

    assert_equal("/sv/demo/assets", routes.localized_path("/demo/assets", locale: "sv"))
    assert_equal("/demo/assets", routes.canonicalize_path("/sv/demo/assets").path)
  end

  def test_example_localized_routes_do_not_translate_dynamic_segments
    routes = localized_routes

    assert_equal("/sv/demo/blogg/tillgangar", routes.localized_path("/demo/blog/[slug]", locale: "sv", slug: "tillgangar"))
    assert_equal("/sv/demo/blogg/shop", routes.localized_href("/demo/blog/shop", locale: "sv"))
    assert_equal("/demo/blog/tillgangar", routes.canonicalize_path("/sv/demo/blogg/tillgangar").path)
  end

  def test_example_localized_routes_keep_unknown_locale_prefixes
    routes = localized_routes
    localized = routes.canonicalize_path("/fr/demo/tillgangar")

    assert_equal("/fr/demo/tillgangar", localized.path)
    assert_equal("en", localized.locale)
    assert_equal("/sv/missing", routes.localized_href("/sv/missing", locale: "sv"))
  end

  def test_example_localized_routes_ignore_headers_without_locale_prefix
    routes = localized_routes
    localized = routes.canonicalize_path("/demo/assets")

    assert_equal("/demo/assets", localized.path)
    assert_equal("en", localized.locale)
    assert_equal("en", localized.route_locale)
  end

  def test_example_i18n_warns_once_for_missing_translations
    translations = {
      "en-US" => {"title" => "Hello"},
      "sv-SE" => {}
    }
    request = localized_request(locale: "sv")

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

  def test_example_app_localizes_form_actions_and_redirects
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    status, response_headers, body = entry.call(BodyRequest["GET", "/sv/demo/formular", HeaderList.new([]), nil], context)
    html = body.join

    assert_equal(200, status)
    assert_includes(html, "action=\"/sv/demo/formular/submit\"")

    cookie = response_headers.fetch("set-cookie").split(";", 2).fetch(0)
    csrf_token = csrf_token_from(html)
    headers = HeaderList.new([
      ["Content-Type", "application/x-www-form-urlencoded"],
      ["Cookie", cookie]
    ])
    form = URI.encode_www_form("csrf_token" => csrf_token, "name" => "Andreas")
    status, response_headers, body = entry.call(BodyRequest["POST", "/sv/demo/formular/submit", headers, form], context)

    assert_equal(302, status)
    assert_equal("/sv/demo/formular", response_headers.fetch("location"))
    assert_empty(body)
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

  def test_example_app_sets_theme_cookie
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    form = URI.encode_www_form("_method" => "put", "value" => "dark", "return_to" => "/docs")
    status, headers, body = entry.call(BodyRequest["POST", "/api/theme", HeaderList.new([]), form], context)

    assert_equal(302, status)
    assert_equal("/docs", headers.fetch("location"))
    assert_includes(headers.fetch("set-cookie"), "#{Example::THEME_COOKIE}=dark")
    assert_includes(headers.fetch("set-cookie"), "SameSite=Lax")
    refute_includes(headers.fetch("set-cookie"), "HttpOnly")
    assert_empty(body)
  end

  def test_example_app_deletes_theme_cookie_for_system_theme
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    form = URI.encode_www_form("_method" => "put", "value" => "system", "return_to" => "/demo")
    status, headers, body = entry.call(BodyRequest["POST", "/api/theme", HeaderList.new([]), form], context)

    assert_equal(302, status)
    assert_equal("/demo", headers.fetch("location"))
    assert_includes(headers.fetch("set-cookie"), "#{Example::THEME_COOKIE}=")
    assert_includes(headers.fetch("set-cookie"), "Max-Age=0")
    refute_includes(headers.fetch("set-cookie"), "HttpOnly")
    assert_empty(body)
  end

  def test_example_app_sanitizes_theme_return_to
    config = example_config
    context = config.context
    entry = context.entry(config.entrypoints.fetch(0))
    form = URI.encode_www_form("_method" => "put", "value" => "dark", "return_to" => "//example.com")
    status, headers, _body = entry.call(BodyRequest["POST", "/api/theme", HeaderList.new([]), form], context)

    assert_equal(302, status)
    assert_equal("/", headers.fetch("location"))
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
    assert(context.assets_for("routes/demo/assets/coffee.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("routes/demo/assets/sailing-boat.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
    assert(context.assets_for("routes/demo/assets/vegetables.jpg").any? { |asset| asset.metadata[:type] == :image_variant })
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
      assert_equal("/app/src/entrypoint.rb", page.module_path)
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

  def localized_request(locale:, path: "/")
    localized = Example::LocalizedRoutes::LocalizedPath.new(path, path, locale, locale)
    Example::Request.from(Request["GET", path], localized: localized)
  end

  def localized_routes(translations: nil)
    route = Data.define(:match_parts)
    Example::LocalizedRoutes.new(
      routes: [
        route.new([[:static, "demo", nil], [:static, "assets", nil]]),
        route.new([[:static, "demo", nil], [:static, "blog", nil], [:dynamic, nil, "slug"]]),
        route.new([[:static, "demo", nil], [:static, "shop", nil], [:optional_catch_all, nil, "filters"]])
      ],
      translations: translations || {
        "en" => {"segments" => {"demo" => "demo", "assets" => "assets", "blog" => "blog", "shop" => "shop"}},
        "sv" => {"segments" => {"demo" => "demo", "assets" => "assets", "blog" => "blogg", "shop" => "butik"}}
      },
      default_locale: "en"
    )
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

  def assert_stylesheet_paths_unique(paths)
    assert_equal(paths.uniq, paths)
  end

  def assert_linked_stylesheets_do_not_import_linked_stylesheets(context, paths)
    paths.each do |path|
      css = context.asset(path).bytes
      imported_linked_paths = paths.reject { |linked_path| linked_path == path }.select { |linked_path| css.include?(linked_path) }

      assert_equal([], imported_linked_paths, "Expected #{path} not to import linked stylesheets")
    end
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
