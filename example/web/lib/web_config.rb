# frozen_string_literal: true

require "klenod/build"
require "klenod/plugin/css"
require "klenod/plugin/javascript"
require "uri"

module Example
  module WebConfig
    APP_ROOT = File.expand_path("..", __dir__)

    module_function

    def build_config(mode: :build)
      Klenod::Build::Config.new(
        source_dir: "src",
        entrypoints: ["/entrypoint.rb"],
        output: "dist/klenod.bundle",
        assets_dir: "dist/public",
        plugins: plugins,
        mode: mode,
        base_dir: APP_ROOT
      )
    end

    def plugins
      [
        Klenod::Build::Plugins::RouterPlugin.new(
          pages_dir: "routes",
          route_base_class: "Example::Route"
        ),
        Klenod::Build::Plugins::RubyPlugin.new,
        Klenod::Build::Plugins::IntlPlugin.new,
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "Example::Component",
          factory: "Example::H",
          component_children: :lazy,
          variables: {
            global: "@__props",
            class: "Example::Context.current"
          },
          i18n_class: "Example::I18n",
          cache_static_subtrees: false
        ),
        Klenod::Build::Plugins::MarkdownPlugin.new(
          component_base_class: "Example::Component",
          factory: "Example::H"
        ),
        Klenod::Build::Plugins::GoogleFontsPlugin.new(
          fetcher: google_fonts_fetcher,
          cache_path: google_fonts_cache_path
        ),
        Klenod::Build::Plugins::CSSPlugin.new,
        Klenod::Build::Plugins::JavaScriptPlugin.new,
        Klenod::Build::Plugins::SvgPlugin.new,
        Klenod::Build::Plugins::ImagePlugin.new(
          widths: [320, 640, 960]
        ),
        Klenod::Build::Plugins::JsonPlugin.new,
        Klenod::Build::Plugins::YamlPlugin.new,
        Klenod::Build::Plugins::TomlPlugin.new,
        Klenod::Build::Plugins::TextPlugin.new
      ]
    end

    def google_fonts_fetcher
      return unless ENV["KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS"]

      # Keep example tests offline and deterministic. Normal builds use the default
      # Google Fonts fetcher and cache the raw CSS response below.
      lambda do |url|
        case url
        when %r{\Ahttps://fonts\.googleapis\.com/css2}
          family_specifier = URI.decode_www_form(URI(url).query || "").to_h.fetch("family")
          family = family_specifier.split(":", 2).fetch(0)
          slug = family.downcase.gsub(/[^a-z0-9]+/, "")
          <<~CSS
            @font-face {
              font-family: #{family.inspect};
              src: url("https://fonts.gstatic.com/s/#{slug}/example.woff2") format("woff2");
            }
          CSS
        when %r{\Ahttps://fonts\.gstatic\.com/s/[^/]+/example\.woff2\z}
          "fake google font"
        else
          raise KeyError, "No Google Fonts fixture for #{url}"
        end
      end
    end

    def google_fonts_cache_path
      File.join(APP_ROOT, "tmp/cache/google_fonts") unless google_fonts_fetcher
    end
  end
end
