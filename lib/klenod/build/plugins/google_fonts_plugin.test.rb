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

      assert_includes(home_css, google_css_asset.output_path)
      assert_includes(google_css_asset.bytes, font_asset.output_path)
      refute_includes(google_css_asset.bytes, "fonts.gstatic.com")
      assert_equal("font/woff2", font_asset.content_type)
      assert_equal("font bytes", font_asset.bytes)
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

  private

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
end
