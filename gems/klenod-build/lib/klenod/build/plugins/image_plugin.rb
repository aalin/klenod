# frozen_string_literal: true

require "image_size"
require "json"
require "rmagick"
require "uri"

require_relative "../asset"
require_relative "../dependency"
require_relative "../hashing"
require_relative "../load_result"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module ImagePlugin
        class Plugin < Klenod::Build::Plugin
          EXTENSIONS = [".avif", ".gif", ".jpeg", ".jpg", ".png", ".webp"].freeze
          IMAGE_RUNTIME_SPECIFIER = "virtual:klenod/image"
          IMAGE_RUNTIME_MODULE_ID = ModuleId.new("#{IMAGE_RUNTIME_SPECIFIER}.rb", nil)

          ImageDefaultKey = ::Data.define(:source_path, :source_hash, :format, :quality)
          ImageVariantKey = ::Data.define(:source_path, :source_hash, :width, :format, :quality)

          def initialize(widths: [], formats: nil)
            @widths = widths
            @formats = formats
            @default_asset_cache = {}
            @variant_cache = {}
          end

          def resolve(dependency, _context)
            return nil unless dependency.specifier == IMAGE_RUNTIME_SPECIFIER

            ResolvedDependency.new(dependency, IMAGE_RUNTIME_MODULE_ID, {virtual: true})
          end

          def load(module_id, context)
            return image_runtime_source if module_id.scheme == :virtual && module_id == IMAGE_RUNTIME_MODULE_ID
            return nil unless EXTENSIONS.include?(module_id.extname)

            source_path = context.absolute_path(module_id)
            source_hash = Hashing.file_hexdigest(source_path)
            dimensions = image_dimensions(source_path)
            image_options = image_options_for(module_id)
            asset = default_image_asset(module_id, source_path, source_hash, dimensions, image_options, context.asset_generation_queue)
            variant_assets = generate_variant_assets(module_id, source_path, source_hash, dimensions, image_options, context.asset_generation_queue)
            javascript_asset = javascript_image_asset(module_id, asset, variant_assets)
            assets = [asset, *variant_assets, javascript_asset]
            image_runtime_dependency =
              Dependency
                .create(
                  specifier: IMAGE_RUNTIME_SPECIFIER,
                  importer_id: module_id,
                  kind: :image_runtime
                )
                .with(id: "#{module_id}:image_runtime")

            transform =
              TransformResult.new(
                image_module_source(module_id, assets, image_runtime_dependency),
                [image_runtime_dependency],
                nil,
                assets,
                [],
                {image_javascript_asset_path: javascript_asset.output_path}
              )
            LoadResult.new(
              image_source(module_id),
              source_hash,
              transform
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

          Dimensions = ::Data.define(:width, :height, :format)

          def image_dimensions(path)
            size = ImageSize.path(path)
            Dimensions.new(size.width, size.height, size.format)
          rescue ImageSize::FormatError
            Dimensions.new(nil, nil, nil)
          end

          def default_image_asset(module_id, source_path, source_hash, dimensions, image_options, queue)
            return static_image_asset(module_id, source_path, source_hash, dimensions) unless generated_default_image?(image_options)

            format = default_image_format(module_id, image_options)
            key = ImageDefaultKey.new(module_id.path, source_hash, format, image_options.quality)
            @default_asset_cache[key] ||= generated_default_image_asset(module_id, source_path, source_hash, dimensions, format, image_options.quality, queue)
          end

          def generated_default_image?(image_options)
            return true if image_options.explicit_formats && image_options.formats.any?

            !image_options.quality.nil?
          end

          def default_image_format(module_id, image_options)
            return image_options.formats.fetch(0) if image_options.explicit_formats && image_options.formats.any?

            module_id.extname.delete_prefix(".")
          end

          def static_image_asset(module_id, source_path, source_hash, dimensions)
            hash = source_hash[0, 16]
            Asset.new(
              module_id.path,
              hash,
              "/assets/#{asset_name(module_id)}.#{hash}#{module_id.extname}",
              source_path,
              nil,
              content_type(module_id.extname),
              {
                type: :image,
                width: dimensions.width,
                height: dimensions.height,
                format: dimensions.format
              }
            )
          end

          def generated_default_image_asset(module_id, source_path, source_hash, dimensions, format, quality, queue)
            format = format.downcase
            extname = ".#{format}"
            hash = Hashing.short("#{source_hash}:default:#{format}:#{quality}")
            metadata = {
              type: :image,
              width: dimensions.width,
              height: dimensions.height,
              format: format.to_sym
            }
            metadata[:quality] = quality if quality

            Asset.generated(
              module_id.path,
              hash,
              "/assets/#{asset_name(module_id)}.#{hash}#{extname}",
              source_path,
              content_type(extname),
              metadata,
              writer: ->(io) { write_image_bytes(source_path, format, quality, io) },
              queue: queue,
              queue_kind: :cpu
            ) do
              generate_image_bytes(source_path, format, quality:)
            end
          end

          def generate_variant_assets(module_id, source_path, source_hash, dimensions, image_options, queue)
            return [] if dimensions.width.nil? || dimensions.height.nil?

            return [] if image_options.widths.empty?

            image_options.formats.flat_map do |format|
              image_options.widths.filter_map do |width|
                next if width <= 0

                key = ImageVariantKey.new(module_id.path, source_hash, width, format.downcase, image_options.quality)
                @variant_cache[key] ||= variant_asset(module_id, source_path, dimensions, source_hash, width, format, image_options.quality, queue)
              end
            end
          end

          ImageOptions = ::Data.define(:widths, :formats, :explicit_formats, :quality)

          def image_runtime_source
            <<~RUBY
              Image =
                ::Data.define(:src, :width, :height, :content_type, :variants) do
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

              ImageVariant = ::Data.define(:src, :width, :height, :content_type, :format, :descriptor, :metadata)
            RUBY
          end

          def image_source(module_id)
            "# image asset: #{module_id}\n"
          end

          def image_module_source(module_id, assets, image_runtime_dependency)
            asset = image_asset(assets)
            variants = image_variant_assets(assets).map { |variant_asset| image_variant_source(variant_asset) }

            <<~RUBY
              ImageRuntime = __klenod_import__(#{image_runtime_dependency.id.inspect})
              Default =
                ImageRuntime::Image.new(
                  src: #{asset.output_path.inspect},
                  width: #{asset.metadata[:width].inspect},
                  height: #{asset.metadata[:height].inspect},
                  content_type: #{asset.content_type.inspect},
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
                content_type: #{asset.content_type.inspect},
                format: #{asset.metadata[:format].inspect},
                descriptor: #{asset.metadata[:descriptor].inspect},
                metadata: #{asset.metadata.inspect}
              )
            RUBY
          end

          def javascript_image_asset(module_id, asset, variant_assets)
            code = javascript_image_module_source(asset, variant_assets)
            hash = Hashing.short(code)
            Asset.new(
              module_id.path,
              hash,
              "#{asset.output_path}.js",
              nil,
              code,
              "application/javascript",
              {type: :image_javascript_metadata, image_metadata: true, image_asset_path: asset.output_path}
            )
          end

          def javascript_image_module_source(asset, variant_assets)
            variants = variant_assets.map { |variant_asset| javascript_image_variant(variant_asset) }
            srcset = variant_assets.empty? ? nil : variant_assets.map { "#{it.output_path} #{it.metadata[:descriptor]}" }.join(", ")
            display_width = variant_assets.filter_map { it.metadata[:width] }.max || asset.metadata[:width]
            sizes = display_width ? "(max-width: #{display_width}px) 100vw, #{display_width}px" : nil
            metadata = {
              src: asset.output_path,
              width: asset.metadata[:width],
              height: asset.metadata[:height],
              contentType: asset.content_type,
              variants: variants,
              srcset: srcset,
              sizes: sizes
            }

            "export default #{JSON.generate(metadata)};\n"
          end

          def javascript_image_variant(asset)
            {
              src: asset.output_path,
              width: asset.metadata[:width],
              height: asset.metadata[:height],
              contentType: asset.content_type,
              format: asset.metadata[:format],
              descriptor: asset.metadata[:descriptor],
              metadata: asset.metadata
            }
          end

          def image_asset(assets)
            assets.find { it.metadata[:type] == :image } || assets.fetch(0)
          end

          def image_variant_assets(assets)
            assets.select { it.metadata[:type] == :image_variant }
          end

          def image_options_for(module_id)
            query = URI.decode_www_form(module_id.query || "").to_h
            widths =
              if query["width"]
                query["width"].split(",").filter_map { |value| Integer(value, exception: false) }
              else
                @widths
              end
            explicit_formats = query.key?("format")
            formats =
              if explicit_formats
                query["format"].split(",")
              else
                @formats || [module_id.extname.delete_prefix(".")]
              end

            ImageOptions.new(widths.uniq, formats.map(&:downcase).uniq, explicit_formats, image_quality(query["quality"]))
          end

          def image_quality(value)
            return nil if value.nil?

            quality = Integer(value, exception: false)
            return nil unless quality&.between?(1, 100)

            quality
          end

          def variant_asset(module_id, source_path, dimensions, source_hash, width, format, quality, queue)
            format = format.downcase
            extname = ".#{format}"
            descriptor = "#{width}w"
            hash = Hashing.short("#{source_hash}:#{width}:#{format}:#{quality}")
            output_path = "/assets/#{asset_name(module_id)}.#{width}w.#{hash}#{extname}"
            metadata = {
              type: :image_variant,
              width: width,
              height: scaled_height(dimensions, width),
              format: format.to_sym,
              descriptor: descriptor,
              source_width: width
            }
            metadata[:quality] = quality if quality

            Asset.generated(
              module_id.path,
              hash,
              output_path,
              source_path,
              content_type(extname),
              metadata,
              writer: ->(io) { write_variant_bytes(source_path, width, format, quality, io) },
              queue: queue,
              queue_kind: :cpu
            ) do
              generate_image_bytes(source_path, format, width: width, quality:)
            end
          end

          def generate_image_bytes(source_path, format, width: nil, quality: nil)
            image = Magick::Image.read(source_path.to_s).first
            output_image = width ? image.resize_to_fit(width) : image
            output_image.to_blob do |info|
              info.format = format.upcase
              info.quality = quality if quality
            end
          ensure
            output_image&.destroy! if output_image && output_image != image
            image&.destroy!
          end

          def write_variant_bytes(source_path, width, format, quality, io)
            io.write(generate_image_bytes(source_path, format, width: width, quality:))
          end

          def write_image_bytes(source_path, format, quality, io)
            io.write(generate_image_bytes(source_path, format, quality:))
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
end
