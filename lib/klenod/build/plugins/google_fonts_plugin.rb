# frozen_string_literal: true

require "digest"
require "net/http"
require "uri"

require_relative "../asset"
require_relative "../dependency"
require_relative "../errors"
require_relative "../module_id"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class GoogleFontsPlugin < Plugin
        GOOGLE_FONTS_HOST = "fonts.googleapis.com"
        GOOGLE_FONTS_PATH = "/css2"
        GOOGLE_FONTS_MODULE_PREFIX = "virtual:klenod/google_fonts"
        FONT_URL_PATTERN = /url\((?<quote>["']?)(?<url>https:\/\/fonts\.gstatic\.com\/[^"')]+)\k<quote>\)/

        Error = Class.new(StandardError)

        def initialize(fetcher: nil)
          @fetcher = fetcher || method(:fetch_url)
          @assets_by_module_id = {}
        end

        def resolve(dependency, _context)
          return nil unless dependency.kind == :css_import
          return nil unless google_fonts_url?(dependency.specifier)

          hash = Digest::SHA256.hexdigest(dependency.specifier)[0, 16]
          module_id =
            ModuleId.new(
              "#{GOOGLE_FONTS_MODULE_PREFIX}/#{hash}.rb",
              URI.encode_www_form("url" => dependency.specifier)
            )

          ResolvedDependency.new(dependency, module_id, {virtual: true})
        end

        def load(module_id, _context)
          return nil unless google_fonts_module?(module_id)

          url = google_fonts_url_for(module_id)
          css = fetch(url)
          font_assets = {}
          rewritten_css =
            css.gsub(FONT_URL_PATTERN) do
              quote = Regexp.last_match[:quote]
              font_url = Regexp.last_match[:url]
              asset = font_assets[font_url] ||= font_asset(font_url)

              %(url(#{quote}#{asset.output_path}#{quote}))
            end

          css_asset = css_asset(module_id, rewritten_css)
          @assets_by_module_id[module_id] = [css_asset, *font_assets.values]
          ruby_module_source(css_asset.output_path)
        end

        def transform(module_id, code, _context)
          return super unless google_fonts_module?(module_id)

          TransformResult.new(
            code,
            [],
            nil,
            @assets_by_module_id.fetch(module_id),
            [],
            {google_fonts_url: google_fonts_url_for(module_id)}
          )
        end

        private

        attr_reader :fetcher

        def google_fonts_url?(value)
          uri = URI.parse(value)
          uri.is_a?(URI::HTTPS) &&
            uri.host == GOOGLE_FONTS_HOST &&
            uri.path == GOOGLE_FONTS_PATH
        rescue URI::InvalidURIError
          false
        end

        def google_fonts_module?(module_id)
          module_id.scheme == :virtual && module_id.path.start_with?("#{GOOGLE_FONTS_MODULE_PREFIX}/")
        end

        def google_fonts_url_for(module_id)
          URI.decode_www_form(module_id.query || "").to_h.fetch("url")
        end

        def fetch(url)
          fetcher.call(url).b
        rescue => error
          raise Error, "Could not download Google Fonts asset #{url.inspect}: #{error.message}"
        end

        def fetch_url(url)
          uri = URI.parse(url)
          response = Net::HTTP.get_response(uri)

          unless response.is_a?(Net::HTTPSuccess)
            raise Error, "HTTP #{response.code}"
          end

          response.body
        end

        def css_asset(module_id, css)
          hash = Digest::SHA256.hexdigest(css)[0, 16]
          output_path = "/assets/#{asset_name(module_id)}.#{hash}.css"

          Asset.new(
            module_id.to_s,
            hash,
            output_path,
            nil,
            css,
            "text/css",
            {type: :css, google_fonts: true}
          )
        end

        def font_asset(url)
          bytes = fetch(url)
          hash = Digest::SHA256.hexdigest(bytes)[0, 16]
          uri = URI.parse(url)
          extname = File.extname(uri.path)
          output_path = "/assets/#{font_asset_name(uri)}.#{hash}#{extname}"

          Asset.new(
            url,
            hash,
            output_path,
            nil,
            bytes,
            content_type(extname),
            {type: :font, google_fonts: true, source_url: url}
          )
        end

        def ruby_module_source(css_asset_path)
          <<~RUBY
            CSS_CLASSES = {}.freeze
            CSS_ASSET_PATH = #{css_asset_path.inspect}
          RUBY
        end

        def asset_name(module_id)
          module_id.path.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
        end

        def font_asset_name(uri)
          basename = File.basename(uri.path, File.extname(uri.path))
          "google_font_#{basename.gsub(/[^A-Za-z0-9]+/, "_")}"
        end

        def content_type(extname)
          case extname
          when ".woff2" then "font/woff2"
          when ".woff" then "font/woff"
          when ".ttf" then "font/ttf"
          when ".otf" then "font/otf"
          else "application/octet-stream"
          end
        end
      end
    end
  end
end
