# frozen_string_literal: true

require "async"
require "async/http/internet"
require "fileutils"
require "uri"

require_relative "../asset"
require_relative "../dependency"
require_relative "../errors"
require_relative "../hashing"
require_relative "../module_id"
require_relative "../plugin"
require_relative "../transform_result"
require_relative "google_fonts_plugin/font_metrics"

module Klenod
  module Build
    module Plugins
      module GoogleFontsPlugin
        class Plugin < Klenod::Build::Plugin
          GOOGLE_FONTS_HOST = "fonts.googleapis.com"
          GOOGLE_FONTS_PATH = "/css2"
          GOOGLE_FONTS_MODULE_PREFIX = "virtual:klenod/google_fonts"
          FONT_URL_PATTERN = /url\((?<quote>["']?)(?<url>https:\/\/fonts\.gstatic\.com\/[^"')]+)\k<quote>\)/

          Error = Class.new(StandardError)
          FontFace = Data.define(:family, :style, :weight)

          class CssCache
            def initialize(path)
              @path = path
            end

            def read(url)
              path = entry_path(url)
              return nil unless File.file?(path)

              css = File.binread(path)
              css.empty? ? nil : css
            rescue SystemCallError
              nil
            end

            def write(url, css)
              path = entry_path(url)
              temp_path = "#{path}.tmp.#{$$}.#{object_id}"
              FileUtils.mkdir_p(File.dirname(path))
              File.binwrite(temp_path, css)
              File.rename(temp_path, path)
              css
            rescue
              FileUtils.rm_f(temp_path) if temp_path
              raise
            end

            private

            def entry_path(url)
              hash = Hashing.hexdigest(url)
              File.join(@path, "#{hash}.css")
            end
          end

          class DefaultFetcher
            def initialize(internet: Async::HTTP::Internet.new)
              @internet = internet
            end

            def call(url)
              Sync do
                @internet.get(url) do |response|
                  raise Error, "HTTP #{response.status}" unless response.success?

                  response.read
                end
              end
            end

            def write(url, io)
              Sync do
                @internet.get(url) do |response|
                  raise Error, "HTTP #{response.status}" unless response.success?

                  if response.body
                    response.body.each { |chunk| io.write(chunk) }
                  else
                    io.write(response.read)
                  end
                end
              end
            end
          end

          class FontFaceParser
            FONT_FACE_PATTERN = /@font-face\s*\{(?<body>.*?)\}/m
            FONT_URL_PATTERN = Plugin::FONT_URL_PATTERN
            DECLARATION_PATTERN = /(?<name>font-family|font-style|font-weight)\s*:\s*(?<value>[^;]+);/i

            def initialize(css)
              @css = css
            end

            def font_faces_by_url
              css.scan(FONT_FACE_PATTERN).each_with_object({}) do |(body), index|
                font_url = body.match(FONT_URL_PATTERN) { it[:url] }
                next unless font_url

                declarations = font_face_declarations(body)
                index[font_url] =
                  FontFace.new(
                    unquote(declarations["font-family"]),
                    declarations["font-style"],
                    declarations["font-weight"]
                  )
              end
            end

            private

            attr_reader :css

            def font_face_declarations(body)
              body.scan(DECLARATION_PATTERN).to_h do |name, value|
                [name.downcase, value.strip]
              end
            end

            def unquote(value)
              value&.delete_prefix("\"")&.delete_suffix("\"")&.delete_prefix("'")&.delete_suffix("'")
            end
          end

          def initialize(fetcher: nil, cache_path: nil, refresh_cache: false, adjust_font_fallback: true)
            @fetcher = fetcher || DefaultFetcher.new
            @css_cache = cache_path && CssCache.new(cache_path)
            @refresh_cache = refresh_cache
            @adjust_font_fallback = adjust_font_fallback
            @fallback_calculator = FallbackCalculator.new(FontMetrics.new)
            @missing_fallback_metrics = {}
            @assets_by_module_id = {}
          end

          def resolve(dependency, _context)
            return nil unless dependency.kind == :css_import
            return nil unless google_fonts_url?(dependency.specifier)

            hash = Hashing.short(dependency.specifier)
            module_id =
              ModuleId.new(
                "#{GOOGLE_FONTS_MODULE_PREFIX}/#{hash}.rb",
                URI.encode_www_form("url" => dependency.specifier)
              )

            ResolvedDependency.new(dependency, module_id, {virtual: true})
          end

          def load(module_id, context)
            return nil unless google_fonts_module?(module_id)

            url = google_fonts_url_for(module_id)
            css = fetch_css(url)
            font_faces = FontFaceParser.new(css).font_faces_by_url
            font_assets = {}
            rewritten_css =
              css.gsub(FONT_URL_PATTERN) do
                quote = Regexp.last_match[:quote]
                font_url = Regexp.last_match[:url]
                asset = font_assets[font_url] ||= font_asset(font_url, font_faces[font_url], context)

                %(url(#{quote}#{asset.output_path}#{quote}))
              end
            rewritten_css = append_fallback_font_faces(rewritten_css, font_faces.values) if @adjust_font_fallback

            css_asset = css_asset(module_id, url, rewritten_css, font_assets.keys)
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
            @fetcher.call(url).b
          rescue => error
            raise Error, "Could not download Google Fonts asset #{url.inspect}: #{error.message}"
          end

          def fetch_css(url)
            if @css_cache && !@refresh_cache
              css = @css_cache.read(url)
              return css if css
            end

            css = fetch(url)
            @css_cache&.write(url, css)
            css
          end

          def write_fetch(url, io)
            if @fetcher.respond_to?(:write)
              @fetcher.write(url, io)
            else
              io.write(fetch(url))
            end
          rescue => error
            raise Error, "Could not download Google Fonts asset #{url.inspect}: #{error.message}"
          end

          def css_asset(module_id, url, css, font_source_urls)
            hash = Hashing.short(css)
            output_path = "/assets/#{google_fonts_asset_name(url)}.#{hash}.css"

            Asset.new(
              module_id.to_s,
              hash,
              output_path,
              nil,
              css,
              "text/css",
              {type: :css, google_fonts: true, font_source_urls: font_source_urls}
            )
          end

          def append_fallback_font_faces(css, font_faces)
            fallback_css =
              font_faces
                .filter_map(&:family)
                .uniq
                .filter_map { fallback_font_face_css(it) }
            return css if fallback_css.empty?

            "#{css.rstrip}\n\n#{fallback_css.join("\n\n")}\n"
          end

          def fallback_font_face_css(family)
            fallback = @fallback_calculator.call(family)
            unless fallback
              unless @missing_fallback_metrics[family]
                warn "Could not adjust fallback for Google Font #{family.inspect}; run `bundle exec rake google_fonts:metrics:update` to refresh the vendored metrics."
                @missing_fallback_metrics[family] = true
              end
              return
            end

            <<~CSS.rstrip
              @font-face {
                font-family: #{css_string(fallback.family)};
                src: local(#{css_string(fallback.local_family)});
                size-adjust: #{fallback.size_adjust};
                ascent-override: #{fallback.ascent_override};
                descent-override: #{fallback.descent_override};
                line-gap-override: #{fallback.line_gap_override};
              }
            CSS
          end

          def css_string(value)
            %("#{value.gsub("\\", "\\\\").gsub("\"", "\\\"")}")
          end

          def font_asset(url, font_face, context)
            hash = Hashing.short(url)
            uri = URI.parse(url)
            extname = File.extname(uri.path)
            output_path = "/assets/#{font_asset_name(uri, font_face)}.#{hash}#{extname}"

            Asset.generated(
              url,
              hash,
              output_path,
              nil,
              content_type(extname),
              {
                type: :font,
                google_fonts: true,
                source_url: url,
                family: font_face&.family,
                style: font_face&.style,
                weight: font_face&.weight
              },
              writer: ->(io) { write_fetch(url, io) },
              queue: context.asset_generation_queue,
              queue_kind: :io
            ) do
              fetch(url)
            end
          end

          def ruby_module_source(css_asset_path)
            <<~RUBY
              CSS_CLASSES = {}.freeze
              CSS_ASSET_PATH = #{css_asset_path.inspect}
            RUBY
          end

          def google_fonts_asset_name(url)
            uri = URI.parse(url)
            families =
              URI
                .decode_www_form(uri.query || "")
                .filter_map do |key, value|
                  next unless key == "family"

                  value.split(":", 2).fetch(0)
                end

            slug = families.empty? ? "fonts" : families.join("_")
            "google_fonts_#{slugify(slug)}"
          end

          def font_asset_name(uri, font_face)
            return font_face_asset_name(font_face) if font_face&.family

            parts = uri.path.split("/").reject(&:empty?)
            useful_parts = parts.last(3)
            useful_parts[-1] = File.basename(useful_parts.fetch(-1), File.extname(useful_parts.fetch(-1)))

            "google_font_#{slugify(useful_parts.join("_"))}"
          end

          def font_face_asset_name(font_face)
            parts = [font_face.family, font_face.style, font_face.weight].compact

            "google_font_#{slugify(parts.join("_"))}"
          end

          def slugify(value)
            value
              .downcase
              .gsub(/[^a-z0-9]+/, "_")
              .sub(/\A_+/, "")
              .sub(/_+\z/, "")
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

        Error = Plugin::Error
        FontFace = Plugin::FontFace
        CssCache = Plugin::CssCache
        DefaultFetcher = Plugin::DefaultFetcher
      end
    end
  end
end
