# frozen_string_literal: true

require_relative "../asset"
require_relative "../dependency"
require_relative "../errors"
require_relative "../hashing"
require_relative "../module_id"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class SvgPlugin < Plugin
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

        def transform(module_id, code, _context)
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
          svg_runtime_dependency =
            Dependency
              .create(
                specifier: SVG_RUNTIME_SPECIFIER,
                importer_id: module_id,
                kind: :svg_runtime
              )
              .with(id: "#{module_id}:svg_runtime")

          TransformResult.new(
            svg_module_source(asset, svg_runtime_dependency),
            [svg_runtime_dependency],
            nil,
            [asset],
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

        Dimensions = Data.define(:width, :height)

        def svg_runtime_source
          <<~RUBY
            Svg = Data.define(:src, :width, :height, :content_type)
          RUBY
        end

        def svg_module_source(asset, svg_runtime_dependency)
          <<~RUBY
            SvgRuntime = __klenod_import__(#{svg_runtime_dependency.id.inspect})
            Default =
              SvgRuntime::Svg.new(
                src: #{asset.output_path.inspect},
                width: #{asset.metadata[:width].inspect},
                height: #{asset.metadata[:height].inspect},
                content_type: #{asset.content_type.inspect}
              )

          RUBY
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
