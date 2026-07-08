# frozen_string_literal: true

require "digest"
require "image_size"
require "rmagick"
require "uri"

require_relative "../asset"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class ImagePlugin < Plugin
        EXTENSIONS = [".avif", ".gif", ".jpeg", ".jpg", ".png", ".webp"].freeze

        Image = Data.define(:src, :width, :height, :variants)
        ImageVariant = Data.define(:src, :width, :height, :format, :descriptor, :metadata)
        ImageVariantKey = Data.define(:source_path, :source_hash, :width, :format)

        def initialize(widths: [], formats: nil)
          @widths = widths
          @formats = formats
          @variant_cache = {}
        end

        def transform(module_id, code, _context)
          return super unless EXTENSIONS.include?(module_id.extname)

          dimensions = image_dimensions(code)
          hash = Digest::SHA256.hexdigest(code)[0, 16]
          output_path = "/assets/#{asset_name(module_id)}.#{hash}#{module_id.extname}"
          logical_name = module_id.path
          asset =
            Asset.new(
              logical_name,
              hash,
              output_path,
              nil,
              code,
              content_type(module_id.extname),
              {
                type: :image,
                width: dimensions.width,
                height: dimensions.height,
                format: dimensions.format
              }
            )
          variant_assets = generate_variant_assets(module_id, code, dimensions)

          TransformResult.new("", [], nil, [asset, *variant_assets], [], {asset_bytes: code})
        end

        def import_value(_resolved_dependency, record, _context)
          return nil unless EXTENSIONS.include?(record.id.extname)

          asset = record.assets.first
          variants =
            record
              .assets
              .drop(1)
              .map do |variant_asset|
                ImageVariant.new(
                  variant_asset.output_path,
                  variant_asset.metadata[:width],
                  variant_asset.metadata[:height],
                  variant_asset.metadata[:format],
                  variant_asset.metadata[:descriptor],
                  variant_asset.metadata
                )
              end

          Image.new(
            asset.output_path,
            asset.metadata[:width],
            asset.metadata[:height],
            variants
          )
        end

        private

        Dimensions = Data.define(:width, :height, :format)

        def image_dimensions(bytes)
          size = ImageSize.new(bytes)
          Dimensions.new(size.width, size.height, size.format)
        rescue ImageSize::FormatError
          Dimensions.new(nil, nil, nil)
        end

        def generate_variant_assets(module_id, bytes, dimensions)
          return [] if dimensions.width.nil? || dimensions.height.nil?

          variant_options = variant_options_for(module_id)
          return [] if variant_options.widths.empty?

          image = Magick::Image.from_blob(bytes).first
          source_hash = Digest::SHA256.hexdigest(bytes)

          variant_options.formats.flat_map do |format|
            variant_options.widths.filter_map do |width|
              next if width <= 0

              key = ImageVariantKey.new(module_id.path, source_hash, width, format.downcase)
              @variant_cache[key] ||= generate_variant_asset(module_id, image, width, format)
            end
          end
        rescue Magick::ImageMagickError
          []
        ensure
          image&.destroy!
        end

        VariantOptions = Data.define(:widths, :formats)

        def variant_options_for(module_id)
          query = URI.decode_www_form(module_id.query || "").to_h
          widths =
            if query["width"]
              query["width"].split(",").filter_map { |value| Integer(value, exception: false) }
            else
              @widths
            end
          formats =
            if query["format"]
              query["format"].split(",")
            else
              @formats || [module_id.extname.delete_prefix(".")]
            end

          VariantOptions.new(widths.uniq, formats.map(&:downcase).uniq)
        end

        def generate_variant_asset(module_id, image, width, format)
          variant_image = image.resize_to_fit(width)
          variant_bytes = variant_image.to_blob { |info| info.format = format.upcase }
          variant_dimensions = image_dimensions(variant_bytes)
          hash = Digest::SHA256.hexdigest(variant_bytes)[0, 16]
          extname = ".#{format.downcase}"
          output_path = "/assets/#{asset_name(module_id)}.#{width}w.#{hash}#{extname}"

          Asset.new(
            module_id.path,
            hash,
            output_path,
            nil,
            variant_bytes,
            content_type(extname),
            {
              type: :image_variant,
              width: variant_dimensions.width,
              height: variant_dimensions.height,
              format: variant_dimensions.format || format.downcase.to_sym,
              descriptor: "#{width}w",
              source_width: width
            }
          )
        ensure
          variant_image&.destroy!
        end

        def asset_name(module_id)
          File.basename(module_id.path, module_id.extname).gsub(/[^A-Za-z0-9]+/, "_")
        end

        def content_type(extname)
          case extname
          when ".avif" then "image/avif"
          when ".gif" then "image/gif"
          when ".jpeg", ".jpg" then "image/jpeg"
          when ".png" then "image/png"
          when ".webp" then "image/webp"
          else "application/octet-stream"
          end
        end
      end
    end
  end
end
