# frozen_string_literal: true

require_relative "lib/framework"
require "klenod"

source_dir "src"
entrypoint "pages/server"
output "dist/klenod.bundle"
assets_dir "dist/public"

google_fonts_fetcher =
  if ENV["KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS"]
    # Keep example tests offline and deterministic. Normal builds use the default
    # Google Fonts fetcher and cache the raw CSS response below.
    lambda do |url|
      case url
      when %r{\Ahttps://fonts\.googleapis\.com/css2}
        <<~CSS
          @font-face {
            font-family: "Source Sans 3";
            src: url("https://fonts.gstatic.com/s/sourcesans3/example.woff2") format("woff2");
          }
        CSS
      when "https://fonts.gstatic.com/s/sourcesans3/example.woff2"
        "fake source sans font"
      else
        raise KeyError, "No Google Fonts fixture for #{url}"
      end
    end
  end
google_fonts_cache_path = File.expand_path("tmp/cache/google_fonts", __dir__) unless google_fonts_fetcher

plugins [
  Klenod::Build::Plugins::RouterPlugin.new(
    route_base_class: "Example::Route"
  ),
  Klenod::Build::Plugins::RubyPlugin.new,
  Klenod::Build::Plugins::IntlPlugin.new,
  Klenod::Build::Plugins::HamlPlugin.new(
    component_base_class: "Example::Component",
    factory: "Example::H"
  ),
  Klenod::Build::Plugins::GoogleFontsPlugin.new(
    fetcher: google_fonts_fetcher,
    cache_path: google_fonts_cache_path
  ),
  Klenod::Build::Plugins::CssPlugin.new,
  Klenod::Build::Plugins::SvgPlugin.new,
  Klenod::Build::Plugins::ImagePlugin.new(
    widths: [320, 640, 960]
  ),
  Klenod::Build::Plugins::JsonPlugin.new,
  Klenod::Build::Plugins::YamlPlugin.new,
  Klenod::Build::Plugins::TomlPlugin.new,
  Klenod::Build::Plugins::TextPlugin.new
]
