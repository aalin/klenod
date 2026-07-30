# frozen_string_literal: true

require_relative "lib/framework"
require "klenod"

source_dir "src"
entrypoint "/entrypoint.rb"
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
  Klenod::Build::Plugins::RouterPlugin::Plugin.new(
    pages_dir: "routes",
    route_base_class: "Example::Route"
  ),
  Klenod::Build::Plugins::RubyPlugin::Plugin.new,
  Klenod::Build::Plugins::IntlPlugin::Plugin.new,
  Klenod::Build::Plugins::HamlPlugin::Plugin.new(
    component_base_class: "Example::Component",
    factory: "Example::H",
    global_variables: "@__props",
    cache_static_subtrees: false
  ),
  Klenod::Build::Plugins::MarkdownPlugin::Plugin.new(
    component_base_class: "Example::Component",
    factory: "Example::H"
  ),
  Klenod::Build::Plugins::GoogleFontsPlugin::Plugin.new(
    fetcher: google_fonts_fetcher,
    cache_path: google_fonts_cache_path
  ),
  Klenod::Build::Plugins::CssPlugin::Plugin.new,
  Klenod::Build::Plugins::SvgPlugin::Plugin.new,
  Klenod::Build::Plugins::ImagePlugin::Plugin.new(
    widths: [320, 640, 960]
  ),
  Klenod::Build::Plugins::JsonPlugin::Plugin.new,
  Klenod::Build::Plugins::YamlPlugin::Plugin.new,
  Klenod::Build::Plugins::TomlPlugin::Plugin.new,
  Klenod::Build::Plugins::TextPlugin::Plugin.new
]
