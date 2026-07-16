# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
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
      refute(font_asset.ready?)
      assert_equal("font bytes", font_asset.bytes)
      assert(font_asset.ready?)
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

  def context_with(dir, plugin)
    Klenod::Build::Context.new(
      source_dir: dir,
      plugins: [
        plugin,
        Klenod::Build::Plugins::CssPlugin.new
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
