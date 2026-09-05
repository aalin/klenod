# frozen_string_literal: true

require_relative "../asset"
require_relative "../dependency"
require_relative "../errors"
require_relative "../hashing"
require_relative "../module_id"
require_relative "../plugin"
require_relative "../transform_result"
require_relative "asset_javascript_metadata"

module Klenod
  module Build
    module Plugins
      module SvgPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class Plugin < Klenod::Build::Plugin
          EXTENSIONS = [".svg"].freeze
          SVG_RUNTIME_SPECIFIER = "virtual:klenod/svg"
          SVG_RUNTIME_MODULE_ID = ModuleId.new("#{SVG_RUNTIME_SPECIFIER}.rb", nil)

          def resolve(dependency, _context)
            return nil unless dependency.specifier == SVG_RUNTIME_SPECIFIER

            ResolvedDependency.new(dependency, SVG_RUNTIME_MODULE_ID, {virtual: true})
          end

          def load(module_id, _context)
            return nil unless module_id.scheme == :virtual && module_id == SVG_RUNTIME_MODULE_ID

            svg_runtime_source
          end

          def transform(module_id, code, context)
            return super unless EXTENSIONS.include?(module_id.extname)

            raise UnsupportedFileError, "SVG imports do not support query options: #{module_id}" if module_id.query

            dimensions = svg_dimensions(code)
            hash = Hashing.short(code)
            output_path = "/assets/#{asset_name(module_id)}.#{hash}.svg"
            asset =
              Asset.new(
                module_id.path,
                hash,
                output_path,
                nil,
                code,
                "image/svg+xml",
                {
                  type: :svg,
                  width: dimensions.width,
                  height: dimensions.height
                }
              )
            javascript_asset = javascript_svg_asset(module_id, asset, context)
            svg_runtime_dependency =
              Dependency
                .create(
                  specifier: SVG_RUNTIME_SPECIFIER,
                  importer_id: module_id,
                  kind: :svg_runtime
                )
                .with(id: "#{module_id}:svg_runtime")

            TransformResult.new(
              svg_module_source(asset, svg_runtime_dependency, context),
              [svg_runtime_dependency],
              nil,
              [asset],
              [],
              {asset_bytes: code, svg_javascript_asset: javascript_asset}
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

          Dimensions = Data.define(:width, :height)

          def svg_runtime_source
            <<~RUBY
              SvgMetadata = Data.define(:src, :width, :height, :content_type, :aspect_ratio) do
                alias to_s src
              end
            RUBY
          end

          def svg_module_source(asset, svg_runtime_dependency, context)
            <<~RUBY
              SvgRuntime = __klenod_import__(#{svg_runtime_dependency.id.inspect})
              Default =
                SvgRuntime::SvgMetadata.new(
                  src: #{context.asset_url(asset).inspect},
                  width: #{asset.metadata[:width].inspect},
                  height: #{asset.metadata[:height].inspect},
                  content_type: #{asset.content_type.inspect},
                  aspect_ratio: #{AssetJavaScriptMetadata.aspect_ratio(asset.metadata[:width], asset.metadata[:height]).inspect}
                )

            RUBY
          end

          def javascript_svg_asset(module_id, asset, context)
            code = javascript_svg_module_source(asset, context)
            hash = Hashing.short(code)
            Asset.new(
              module_id.path,
              hash,
              "/assets/#{asset_name(module_id)}.#{hash}#{module_id.extname}.js",
              nil,
              code,
              "application/javascript",
              {type: :svg_javascript_metadata, svg_metadata: true, svg_asset_path: asset.output_path}
            )
          end

          def javascript_svg_module_source(asset, context)
            metadata = {
              src: context.asset_url(asset),
              width: asset.metadata[:width],
              height: asset.metadata[:height],
              contentType: asset.content_type,
              aspectRatio: AssetJavaScriptMetadata.aspect_ratio(asset.metadata[:width], asset.metadata[:height])
            }

            <<~JAVASCRIPT
              import { SvgMetadata } from #{AssetJavaScriptMetadata::OUTPUT_PATH.inspect};
              export default new SvgMetadata(#{AssetJavaScriptMetadata.object_literal(metadata)});
            JAVASCRIPT
          end

          def svg_dimensions(code)
            attributes = svg_attributes(code)
            return Dimensions.new(nil, nil) unless attributes

            explicit_width = parse_length(attributes["width"])
            explicit_height = parse_length(attributes["height"])
            return Dimensions.new(explicit_width, explicit_height) if explicit_width && explicit_height

            view_box_dimensions(attributes["viewBox"] || attributes["viewbox"])
          end

          def svg_attributes(code)
            match = code.match(/<svg(?=[\s>])(?<attributes>[^>]*)>/im)
            return nil unless match

            match[:attributes].scan(/([:\w.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/).to_h do |name, double_quoted, single_quoted, unquoted|
              [name, double_quoted || single_quoted || unquoted]
            end
          end

          def view_box_dimensions(view_box)
            values = view_box.to_s.split(/[,\s]+/).filter_map { |value| parse_number(value) }
            return Dimensions.new(nil, nil) unless values.length == 4

            width = positive_number(values.fetch(2))
            height = positive_number(values.fetch(3))
            Dimensions.new(width, height)
          end

          def parse_length(value)
            match = value.to_s.strip.match(/\A(?<number>[+-]?(?:\d+(?:\.\d+)?|\.\d+))(?:px)?\z/i)
            return nil unless match

            positive_number(parse_number(match[:number]))
          end

          def parse_number(value)
            number = Float(value, exception: false)
            return nil unless number&.finite?

            number
          end

          def positive_number(number)
            return nil unless number&.positive?

            (number == number.to_i) ? number.to_i : number
          end

          def asset_name(module_id)
            File.basename(module_id.path, module_id.extname).gsub(/[^A-Za-z0-9]+/, "_")
          end
        end
      end
    end
  end
end
