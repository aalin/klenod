# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require "klenod/plugin/css"
require_relative "google_fonts_plugin"

class Klenod::Build::Plugins::GoogleFontsPlugin::Test < Minitest::Test
  GOOGLE_CSS_URL = "https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@400;700&display=swap"
  FONT_URL = "https://fonts.gstatic.com/s/sourcesans3/v1/source-sans-400.woff2"
  OTHER_FONT_URL = "https://fonts.gstatic.com/s/sourcesans3/v1/source-sans-700.woff2"

  def test_google_fonts_import_emits_local_css_and_font_assets
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n.title { color: red; }\n")
      plugin = plugin_with_responses(
        GOOGLE_CSS_URL => <<~CSS,
          @font-face {
            font-family: "Source Sans 3";
            font-style: normal;
            font-weight: 400;
            src: url("#{FONT_URL}") format("woff2");
          }
        CSS
        FONT_URL => "font bytes"
      )

      context = context_with(dir, plugin)
      record = context.evaluate("styles/home.css")
      home_css = record.assets.first.bytes
      google_css_asset = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :css }
      font_asset = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :font }

      refute_includes(home_css, google_css_asset.output_path)
      refute_includes(home_css, "@import")
      assert_includes(google_css_asset.bytes, font_asset.output_path)
      refute_includes(google_css_asset.bytes, "fonts.gstatic.com")
      assert_match(%r{\A/assets/google_fonts_source_sans_3\.[a-f0-9]{16}\.css\z}, google_css_asset.output_path)
      assert_match(%r{\A/assets/google_font_source_sans_3_normal_400\.[a-f0-9]{16}\.woff2\z}, font_asset.output_path)
      assert_equal([FONT_URL], google_css_asset.metadata[:font_source_urls])
      assert_equal("font/woff2", font_asset.content_type)
      assert_equal("Source Sans 3", font_asset.metadata[:family])
      assert_equal("normal", font_asset.metadata[:style])
      assert_equal("400", font_asset.metadata[:weight])
      assert_equal(:io, font_asset.queue_kind)
      assert_includes(google_css_asset.bytes, <<~CSS)
        @font-face {
          font-family: "Source Sans 3 Fallback";
          src: local("Arial");
          size-adjust: 93.76%;
          ascent-override: 109.21%;
          descent-override: 42.66%;
          line-gap-override: 0.00%;
        }
      CSS
      refute(font_asset.ready?)
      assert_equal("font bytes", font_asset.bytes)
      assert(font_asset.ready?)
    end
  end

  def test_fallback_calculator_matches_next_style_roboto_metrics
    metrics = Klenod::Build::Plugins::GoogleFontsPlugin::FontMetrics.new
    calculator = Klenod::Build::Plugins::GoogleFontsPlugin::FallbackCalculator.new(metrics)
    fallback = calculator.call("Roboto")

    assert_equal("Roboto Fallback", fallback.family)
    assert_equal("Arial", fallback.local_family)
    assert_equal("99.78%", fallback.size_adjust)
    assert_equal("92.98%", fallback.ascent_override)
    assert_equal("24.47%", fallback.descent_override)
    assert_equal("0.00%", fallback.line_gap_override)
    assert_equal("Courier New", calculator.call("IBM Plex Mono").local_family)
  end

  def test_serif_fonts_use_times_new_roman_and_repeated_faces_share_one_fallback
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      plugin = plugin_with_responses(
        GOOGLE_CSS_URL => <<~CSS,
          @font-face {
            font-family: "Source Serif 4";
            font-style: normal;
            font-weight: 400;
            src: url("#{FONT_URL}") format("woff2");
          }
          @font-face {
            font-family: "Source Serif 4";
            font-style: normal;
            font-weight: 700;
            src: url("#{OTHER_FONT_URL}") format("woff2");
          }
        CSS
        FONT_URL => "regular font bytes",
        OTHER_FONT_URL => "bold font bytes"
      )

      context = context_with(dir, plugin)
      context.evaluate("styles/home.css")
      css = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :css }.bytes

      assert_equal(1, css.scan('font-family: "Source Serif 4 Fallback"').length)
      assert_includes(css, 'src: local("Times New Roman")')
      assert_includes(css, "size-adjust: 117.91%")
    end
  end

  def test_adjust_font_fallback_can_be_disabled
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      plugin =
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          adjust_font_fallback: false,
          fetcher: ->(url) do
            {
              GOOGLE_CSS_URL => <<~CSS,
                @font-face {
                  font-family: "Source Sans 3";
                  src: url("#{FONT_URL}") format("woff2");
                }
              CSS
              FONT_URL => "font bytes"
            }.fetch(url)
          end
        )

      context = context_with(dir, plugin)
      context.evaluate("styles/home.css")
      css = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :css }.bytes

      refute_includes(css, "Fallback")
      refute_includes(css, "size-adjust")
    end
  end

  def test_missing_metrics_warn_once_and_keep_original_font_faces
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      plugin = plugin_with_responses(
        GOOGLE_CSS_URL => <<~CSS,
          @font-face {
            font-family: "A Font From The Future";
            src: url("#{FONT_URL}") format("woff2");
          }
          @font-face {
            font-family: "A Font From The Future";
            src: url("#{OTHER_FONT_URL}") format("woff2");
          }
        CSS
        FONT_URL => "regular font bytes",
        OTHER_FONT_URL => "bold font bytes"
      )

      _stdout, stderr = capture_io do
        context = context_with(dir, plugin)
        context.evaluate("styles/home.css")
        css = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :css }.bytes

        assert_equal(2, css.scan('font-family: "A Font From The Future"').length)
        refute_includes(css, "A Font From The Future Fallback")
      end

      assert_equal(1, stderr.scan("A Font From The Future").length)
      assert_includes(stderr, "google_fonts:metrics:update")
    end
  end

  def test_build_bundle_includes_google_fonts_stylesheet_for_importing_css
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n.title { color: red; }\n")
      plugin = plugin_with_responses(
        GOOGLE_CSS_URL => %(@font-face { src: url("#{FONT_URL}") format("woff2"); }),
        FONT_URL => "font bytes"
      )

      context = context_with(dir, plugin, mode: :build)
      bundle = context.build(entrypoints: ["styles/home.css"], output: "#{dir}/bundle.mpk")
      css_assets = bundle.assets_for_module("styles/home.css", type: :css)

      assert_equal(2, css_assets.length)
      assert(css_assets.fetch(0).metadata[:google_fonts])
      assert_equal("styles/home.css", css_assets.fetch(1).logical_name)
    end
  end

  def test_google_fonts_import_deduplicates_repeated_font_urls
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      plugin = plugin_with_responses(
        GOOGLE_CSS_URL => <<~CSS,
          @font-face { src: url("#{FONT_URL}") format("woff2"); }
          @font-face { src: url("#{FONT_URL}") format("woff2"); }
          @font-face { src: url("#{OTHER_FONT_URL}") format("woff2"); }
        CSS
        FONT_URL => "regular font bytes",
        OTHER_FONT_URL => "bold font bytes"
      )

      context = context_with(dir, plugin)
      context.evaluate("styles/home.css")
      font_assets = context.assets.values.select { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :font }

      assert_equal(2, font_assets.length)
      assert_equal([FONT_URL, OTHER_FONT_URL].sort, font_assets.map { |asset| asset.metadata[:source_url] }.sort)
    end
  end

  def test_google_font_files_are_downloaded_lazily
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      fetched = []
      plugin =
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          fetcher: lambda do |url|
            fetched << url
            case url
            when GOOGLE_CSS_URL
              %(@font-face { src: url("#{FONT_URL}") format("woff2"); })
            when FONT_URL
              "font bytes"
            else
              raise KeyError, url
            end
          end
        )

      context = context_with(dir, plugin)
      context.evaluate("styles/home.css")
      font_asset = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :font }

      assert_equal([GOOGLE_CSS_URL], fetched)
      assert_equal("font bytes", font_asset.bytes)
      assert_equal([GOOGLE_CSS_URL, FONT_URL], fetched)
    end
  end

  def test_google_fonts_css_cache_miss_fetches_and_writes_raw_css
    Dir.mktmpdir do |dir|
      cache_path = "#{dir}/cache"
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      css = %(@font-face { src: url("#{FONT_URL}") format("woff2"); })
      fetched = []
      plugin =
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          cache_path: cache_path,
          fetcher: lambda do |url|
            fetched << url
            {GOOGLE_CSS_URL => css, FONT_URL => "font bytes"}.fetch(url)
          end
        )

      context_with(dir, plugin).evaluate("styles/home.css")

      assert_equal([GOOGLE_CSS_URL], fetched)
      assert_equal(css, File.binread(cache_entry_path(cache_path, GOOGLE_CSS_URL)))
    end
  end

  def test_google_fonts_css_cache_hit_does_not_fetch_css
    Dir.mktmpdir do |dir|
      cache_path = "#{dir}/cache"
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      cached_css = <<~CSS
        @font-face {
          font-family: "Source Sans 3";
          font-style: normal;
          font-weight: 400;
          src: url("#{FONT_URL}") format("woff2");
        }
      CSS
      write_cache_entry(cache_path, GOOGLE_CSS_URL, cached_css)
      plugin =
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          cache_path: cache_path,
          fetcher: ->(url) { raise "unexpected fetch #{url}" }
        )

      context = context_with(dir, plugin)
      context.evaluate("styles/home.css")
      google_css_asset = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :css }
      font_asset = context.assets.values.find { |asset| asset.metadata[:google_fonts] && asset.metadata[:type] == :font }

      assert_includes(google_css_asset.bytes, font_asset.output_path)
      assert_match(%r{\A/assets/google_font_source_sans_3_normal_400\.[a-f0-9]{16}\.woff2\z}, font_asset.output_path)
    end
  end

  def test_google_fonts_css_cache_refresh_fetches_even_when_cached
    Dir.mktmpdir do |dir|
      cache_path = "#{dir}/cache"
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      write_cache_entry(cache_path, GOOGLE_CSS_URL, "stale css")
      fresh_css = %(@font-face { src: url("#{FONT_URL}") format("woff2"); })
      fetched = []
      plugin =
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          cache_path: cache_path,
          refresh_cache: true,
          fetcher: lambda do |url|
            fetched << url
            {GOOGLE_CSS_URL => fresh_css, FONT_URL => "font bytes"}.fetch(url)
          end
        )

      context_with(dir, plugin).evaluate("styles/home.css")

      assert_equal([GOOGLE_CSS_URL], fetched)
      assert_equal(fresh_css, File.binread(cache_entry_path(cache_path, GOOGLE_CSS_URL)))
    end
  end

  def test_google_fonts_css_cache_ignores_empty_entries
    Dir.mktmpdir do |dir|
      cache_path = "#{dir}/cache"
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      write_cache_entry(cache_path, GOOGLE_CSS_URL, "")
      css = %(@font-face { src: url("#{FONT_URL}") format("woff2"); })
      fetched = []
      plugin =
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          cache_path: cache_path,
          fetcher: lambda do |url|
            fetched << url
            {GOOGLE_CSS_URL => css, FONT_URL => "font bytes"}.fetch(url)
          end
        )

      context_with(dir, plugin).evaluate("styles/home.css")

      assert_equal([GOOGLE_CSS_URL], fetched)
      assert_equal(css, File.binread(cache_entry_path(cache_path, GOOGLE_CSS_URL)))
    end
  end

  def test_google_fonts_download_failures_are_clear
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", "@import url(\"#{GOOGLE_CSS_URL}\");\n")
      plugin =
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          fetcher: ->(url) { raise "missing #{url}" }
        )

      error =
        assert_raises(Klenod::Build::Plugins::GoogleFontsPlugin::Error) do
          context_with(dir, plugin).evaluate("styles/home.css")
        end

      assert_includes(error.message, "Could not download Google Fonts asset")
      assert_includes(error.message, GOOGLE_CSS_URL)
    end
  end

  def test_default_fetcher_downloads_with_async_http_internet
    response = FakeResponse.new(200, "font bytes")
    internet = FakeInternet.new(response)
    fetcher = Klenod::Build::Plugins::GoogleFontsPlugin::DefaultFetcher.new(internet: internet)

    assert_equal("font bytes", fetcher.call(FONT_URL))
    assert_equal([FONT_URL], internet.urls)
    assert(response.closed?)
  end

  def test_default_fetcher_rejects_failed_http_responses
    response = FakeResponse.new(404, "not found")
    internet = FakeInternet.new(response)
    fetcher = Klenod::Build::Plugins::GoogleFontsPlugin::DefaultFetcher.new(internet: internet)

    error =
      assert_raises(Klenod::Build::Plugins::GoogleFontsPlugin::Error) do
        fetcher.call(FONT_URL)
      end

    assert_equal("HTTP 404", error.message)
    assert(response.closed?)
  end

  private

  class FakeInternet
    attr_reader :urls

    def initialize(response)
      @response = response
      @urls = []
    end

    def get(url)
      @urls << url
      yield @response
    ensure
      @response.close
    end
  end

  class FakeResponse
    attr_reader :status

    def initialize(status, body)
      @status = status
      @body = body
      @closed = false
    end

    def success?
      status >= 200 && status < 300
    end

    def read
      @body
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  def context_with(dir, plugin, mode: :development)
    Klenod::Build::Context.new(
      source_dir: dir,
      mode: mode,
      plugins: [
        plugin,
        Klenod::Build::Plugins::CSSPlugin.new
      ]
    )
  end

  def plugin_with_responses(responses)
    Klenod::Build::Plugins::GoogleFontsPlugin.new(
      fetcher: ->(url) { responses.fetch(url) }
    )
  end

  def write_cache_entry(cache_path, url, css)
    path = cache_entry_path(cache_path, url)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, css)
  end

  def cache_entry_path(cache_path, url)
    File.join(cache_path, "#{Klenod::Build::Hashing.hexdigest(url)}.css")
  end
end
