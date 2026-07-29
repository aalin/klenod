# frozen_string_literal: true

require "mayu/css"
require "uri"

require_relative "../asset"
require_relative "../dependency"
require_relative "../errors"
require_relative "../hashing"
require_relative "../plugin"
require_relative "../source_map"
require_relative "class_names_runtime"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class CssPlugin < Plugin
        include ClassNamesRuntime

        CSS_DEPENDENCY_TYPES = {
          Mayu::CSS::ImportDependency => :css_import,
          Mayu::CSS::UrlDependency => :asset_url
        }.freeze

        VALID_SOURCE_MAP_MODES = [false, true, :development].freeze

        def initialize(source_maps: :development)
          unless VALID_SOURCE_MAP_MODES.include?(source_maps)
            raise ArgumentError, "source_maps must be false, true, or :development"
          end

          @source_maps = source_maps
        end

        def resolve(dependency, _context)
          resolve_class_names_runtime(dependency)
        end

        def load(module_id, _context)
          load_class_names_runtime(module_id)
        end

        def transform(module_id, code, context)
          return super unless module_id.extname == ".css"

          result = Mayu::CSS.transform(module_id.path, code, minify: false)
          css_dependencies = build_dependencies(module_id, result.dependencies, context)
          styles_dependency = class_names_runtime_dependency(module_id)

          TransformResult.new(
            ruby_module_source(css_selectors(result), nil, styles_dependency: styles_dependency),
            [styles_dependency, *css_dependencies.dependencies],
            nil,
            [],
            [],
            {
              css_result: result,
              css_classes: css_selectors(result),
              external_dependencies: css_dependencies.external_dependencies
            }
          )
        end

        def finalize(module_id, result, resolved_dependencies, dependency_records, context)
          css_result = result.metadata[:css_result]
          return result unless css_result

          css_edit = replace_dependencies(
            css_result,
            resolved_dependencies,
            dependency_records,
            result.metadata.fetch(:external_dependencies)
          )
          css_edit = remove_empty_imports(css_edit)
          source_map_asset = nil
          css = css_edit.code

          if source_maps_enabled?(context)
            source_map = source_map_for(css_edit.source_map, module_id, context)
            source_map_json = source_map.to_json
            source_map_hash = Hashing.short(source_map_json)
            source_map_output_path = "/assets/#{asset_name(module_id)}.#{source_map_hash}.css.map"
            source_map_asset =
              Asset.new(
                module_id.to_s,
                source_map_hash,
                source_map_output_path,
                nil,
                source_map_json,
                "application/json",
                {type: :css_source_map}
              )
            css = "#{css.chomp}\n/*# sourceMappingURL=#{File.basename(source_map_output_path)} */\n"
          end

          hash = Hashing.short(css)
          output_path = "/assets/#{asset_name(module_id)}.#{hash}.css"
          asset =
            Asset.new(
              module_id.to_s,
              hash,
              output_path,
              nil,
              css,
              "text/css",
              {type: :css, classes: result.metadata[:css_classes]}
            )

          result.with(
            code: ruby_module_source(result.metadata[:css_classes], output_path, styles_dependency: result.dependencies.fetch(0)),
            assets: [asset, source_map_asset, *result.assets].compact,
            metadata: result.metadata.merge(css_asset_path: output_path)
          )
        end

        def import_value(resolved_dependency, record, context)
          styles_import = class_names_runtime_import_value(resolved_dependency, record, context)
          return styles_import if styles_import
          return nil unless record.id.extname == ".css"

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        def runtime_import_value(resolved_dependency, record, _context)
          styles_import = class_names_runtime_runtime_import_value(resolved_dependency, record)
          return styles_import if styles_import
          return Runtime::DefaultImport.new(:Default) if record.id.extname == ".css"

          super
        end

        private

        CssDependencies = Data.define(:dependencies, :external_dependencies)

        def build_dependencies(module_id, dependencies, context)
          external_dependencies = {}
          resolved_dependencies =
            dependencies.each_with_index.filter_map do |dependency, index|
              resolved_dependency =
                Dependency
                  .create(
                    specifier: dependency.url,
                    importer_id: module_id,
                    kind: CSS_DEPENDENCY_TYPES.fetch(dependency.class),
                    loc: dependency.loc,
                    metadata: {placeholder: dependency.placeholder}
                  )
                  .with(id: "#{module_id}:dependency:#{index}")

              if external_url?(dependency.url) && !plugin_resolvable_external_import?(resolved_dependency, dependency, context)
                external_dependencies[dependency.placeholder] = dependency.url
                next
              end

              resolved_dependency
            end

          CssDependencies.new(resolved_dependencies, external_dependencies.freeze)
        end

        def plugin_resolvable_external_import?(dependency, css_dependency, context)
          return false unless css_dependency.is_a?(Mayu::CSS::ImportDependency)

          context.resolve_dependency(dependency)
          true
        rescue ResolveError
          false
        end

        CssEdit = Data.define(:code, :source_map)

        def replace_dependencies(css_result, resolved_dependencies, dependency_records, external_dependencies)
          dependencies_by_placeholder =
            resolved_dependencies.filter_map do |resolved_dependency|
              next unless resolved_dependency.dependency.metadata.key?(:placeholder)

              [resolved_dependency.dependency.metadata.fetch(:placeholder), resolved_dependency]
            end.to_h

          replacements =
            css_result.dependencies.to_h do |css_dependency|
              replacement =
                if external_dependencies.key?(css_dependency.placeholder)
                  external_dependencies.fetch(css_dependency.placeholder)
                else
                  resolved_dependency = dependencies_by_placeholder.fetch(css_dependency.placeholder)
                  record = dependency_records.fetch(resolved_dependency.dependency.id)
                  replacement_for_dependency(resolved_dependency, record)
                end

              [css_dependency.placeholder, replacement]
            end

          map = SourceMap::Map.parse(css_result.source_map)
          edits =
            replacements.map do |placeholder, replacement|
              start_offset = css_result.code.index(placeholder) || raise(KeyError, "Could not find CSS dependency placeholder #{placeholder.inspect}")
              SourceMap::Edit.replace(start_offset, start_offset + placeholder.length, replacement)
            end

          edited = SourceMap::Editor.new(css_result.code, map).apply(edits)
          CssEdit.new(edited.code, edited.source_map)
        end

        def remove_empty_imports(css_edit)
          edits =
            css_edit
              .code
              .to_enum(:scan, /^[ \t]*@import\s+(?:url\(\s*)?["']{2}\s*\)?\s*;\s*\n?/i)
              .map do
                match = Regexp.last_match
                SourceMap::Edit.delete(match.begin(0), match.end(0))
              end

          return css_edit if edits.empty?

          edited = SourceMap::Editor.new(css_edit.code, css_edit.source_map).apply(edits)
          CssEdit.new(edited.code, edited.source_map)
        end

        def source_map_for(source_map, module_id, context)
          inline_origin = context.virtual_module_metadata(module_id)[:inline_css_origin] if context.respond_to?(:virtual_module_metadata)
          return source_map unless inline_origin

          adjusted =
            source_map
              .with(
                sources: [inline_origin.fetch(:module_id).path],
                sources_content: [inline_origin.fetch(:source)]
              )
              .map_original_lines(source_index: 0) { |line| line + inline_origin.fetch(:line_offset) }

          adjusted
            .with(
              segments: adjusted
                .segments
                .map do |segment|
                  if segment.source_index == 0
                    segment.with_original(
                      line: segment.original_line,
                      column: segment.original_column + inline_origin.fetch(:column_offset)
                    )
                  else
                    segment
                  end
                end
            )
        end

        def source_maps_enabled?(context)
          case @source_maps
          when true
            true
          when :development
            context.mode == :development
          else
            false
          end
        end

        def replacement_for_dependency(resolved_dependency, record)
          case resolved_dependency.dependency.kind
          when :css_import
            css_asset = record.assets.find { |asset| asset.metadata[:type] == :css }
            unless css_asset
              raise UnsupportedFileError, "CSS @import #{resolved_dependency.dependency.specifier.inspect} from #{resolved_dependency.dependency.importer_id} resolved to module #{record.id}, which does not emit a CSS asset"
            end
            return ""
          when :asset_url
            unless record.assets.first
              raise UnsupportedFileError, "CSS url() #{resolved_dependency.dependency.specifier.inspect} from #{resolved_dependency.dependency.importer_id} resolved to module #{record.id}, which does not emit an asset"
            end
          end

          record.assets.first&.output_path || record.id.to_s
        end

        def external_url?(value)
          uri = URI.parse(value)
          uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        rescue URI::InvalidURIError
          false
        end

        def ruby_module_source(classes, asset_path, styles_dependency:)
          <<~RUBY
            ClassNames = __klenod_import__(#{styles_dependency.id.inspect})
            CSS_CLASSES = #{classes.inspect}.freeze
            CSS_ASSET_PATH = #{asset_path.inspect}
            Default = ClassNames.new(CSS_CLASSES)
          RUBY
        end

        def css_selectors(result)
          result.classes.merge(result.elements.transform_keys { :"__#{it}" })
        end

        def asset_name(module_id)
          module_id.path.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
        end
      end
    end
  end
end
