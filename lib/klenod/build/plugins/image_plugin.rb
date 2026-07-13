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
        IMAGE_RUNTIME_SPECIFIER = "virtual:klenod/image"
        IMAGE_RUNTIME_MODULE_ID = ModuleId.new("#{IMAGE_RUNTIME_SPECIFIER}.rb", nil)

        ImageVariantKey = Data.define(:source_path, :source_hash, :width, :format)

        def initialize(widths: [], formats: nil)
          @widths = widths
          @formats = formats
          @variant_cache = {}
        end

        def resolve(dependency, _context)
          return nil unless dependency.specifier == IMAGE_RUNTIME_SPECIFIER

          ResolvedDependency.new(dependency, IMAGE_RUNTIME_MODULE_ID, {virtual: true})
        end

        def load(module_id, _context)
          return nil unless module_id.scheme == :virtual && module_id == IMAGE_RUNTIME_MODULE_ID

          image_runtime_source
        end

        def transform(module_id, code, context)
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
          variant_assets = generate_variant_assets(module_id, code, dimensions, context.asset_generation_queue)
          assets = [asset, *variant_assets]
          image_runtime_dependency =
            Dependency
              .create(
                specifier: IMAGE_RUNTIME_SPECIFIER,
                importer_id: module_id,
                kind: :image_runtime
              )
              .with(id: "#{module_id}:image_runtime")

          TransformResult.new(
            image_module_source(module_id, assets, image_runtime_dependency),
            [image_runtime_dependency],
            nil,
            assets,
            [],
            {asset_bytes: code}
          )
        end

        def import_value(_resolved_dependency, record, context)
          return nil unless EXTENSIONS.include?(record.id.extname)

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        def runtime_import_value(_resolved_dependency, record, _context)
          return Runtime::DefaultImport.new(:Default) if EXTENSIONS.include?(record.id.extname)

          super
        end

        private

        Dimensions = Data.define(:width, :height, :format)

        def image_dimensions(bytes)
          size = ImageSize.new(bytes)
          Dimensions.new(size.width, size.height, size.format)
        rescue ImageSize::FormatError
          Dimensions.new(nil, nil, nil)
        end

        def generate_variant_assets(module_id, bytes, dimensions, queue)
          return [] if dimensions.width.nil? || dimensions.height.nil?

          variant_options = variant_options_for(module_id)
          return [] if variant_options.widths.empty?

          source_hash = Digest::SHA256.hexdigest(bytes)

          variant_options.formats.flat_map do |format|
            variant_options.widths.filter_map do |width|
              next if width <= 0

              key = ImageVariantKey.new(module_id.path, source_hash, width, format.downcase)
              @variant_cache[key] ||= variant_asset(module_id, bytes, dimensions, source_hash, width, format, queue)
            end
          end
        end

        VariantOptions = Data.define(:widths, :formats)

        def image_runtime_source
          <<~RUBY
            Image =
              Data.define(:src, :width, :height, :variants) do
                def srcset
                  return nil if variants.empty?

                  variants.map { "\#{it.src} \#{it.descriptor}" }.join(", ")
                end

                def sizes
                  display_width = variants.filter_map(&:width).max || width
                  return nil unless display_width

                  "(max-width: \#{display_width}px) 100vw, \#{display_width}px"
                end
              end

            ImageVariant = Data.define(:src, :width, :height, :format, :descriptor, :metadata)
          RUBY
        end

        def image_module_source(module_id, assets, image_runtime_dependency)
          asset = assets.fetch(0)
          variants = assets.drop(1).map { |variant_asset| image_variant_source(variant_asset) }

          <<~RUBY
            ImageRuntime = __klenod_import__(#{image_runtime_dependency.id.inspect})
            Default =
              ImageRuntime::Image.new(
                src: #{asset.output_path.inspect},
                width: #{asset.metadata[:width].inspect},
                height: #{asset.metadata[:height].inspect},
                variants: [
                  #{variants.join(",\n    ")}
                ]
              )

          RUBY
        end

        def image_variant_source(asset)
          <<~RUBY.chomp
            ImageRuntime::ImageVariant.new(
              src: #{asset.output_path.inspect},
              width: #{asset.metadata[:width].inspect},
              height: #{asset.metadata[:height].inspect},
              format: #{asset.metadata[:format].inspect},
              descriptor: #{asset.metadata[:descriptor].inspect},
              metadata: #{asset.metadata.inspect}
            )
          RUBY
        end

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

        def variant_asset(module_id, bytes, dimensions, source_hash, width, format, queue)
          format = format.downcase
          extname = ".#{format}"
          descriptor = "#{width}w"
          hash = Digest::SHA256.hexdigest("#{source_hash}:#{width}:#{format}")[0, 16]
          output_path = "/assets/#{asset_name(module_id)}.#{width}w.#{hash}#{extname}"
          metadata = {
            type: :image_variant,
            width: width,
            height: scaled_height(dimensions, width),
            format: format.to_sym,
            descriptor: descriptor,
            source_width: width
          }

          Asset.generated(
            module_id.path,
            hash,
            output_path,
            nil,
            content_type(extname),
            metadata,
            queue: queue,
            queue_kind: :cpu
          ) do
            generate_variant_bytes(bytes, width, format)
          end
        end

        def generate_variant_bytes(bytes, width, format)
          image = Magick::Image.from_blob(bytes).first
          variant_image = image.resize_to_fit(width)
          variant_bytes = variant_image.to_blob { |info| info.format = format.upcase }
          variant_bytes
        ensure
          variant_image&.destroy!
          image&.destroy!
        end

        def scaled_height(dimensions, width)
          return nil if dimensions.width.nil? || dimensions.height.nil? || dimensions.width.zero?

          (dimensions.height.to_f * width / dimensions.width).round
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
