# frozen_string_literal: true

require "klenod/plugin/css/transformer"
require "uri"

require "klenod/build/asset"
require "klenod/build/dependency"
require "klenod/build/errors"
require "klenod/build/hashing"
require "klenod/build/plugin"
require "klenod/build/source_map"
require "klenod/build/transform_result"
require "klenod/build/plugins/class_names_runtime"

module Klenod
  module Build
    module Plugins
      module CssPlugin
        class Plugin < Klenod::Build::Plugin
          include ClassNamesRuntime

          CSS_DEPENDENCY_TYPES = {
            Klenod::Plugin::CSS::ImportDependency => :css_import,
            Klenod::Plugin::CSS::UrlDependency => :asset_url
          }.freeze

          JAVASCRIPT_STYLESHEET_QUERY = "javascript"
          VALID_SOURCE_MAP_MODES = [false, true, :development].freeze

          def initialize(source_maps: :development, minify: false, class_pattern: "[component].[local]?[hash]", tag_pattern: "[component]_[local]?[hash]")
            unless VALID_SOURCE_MAP_MODES.include?(source_maps)
              raise ArgumentError, "source_maps must be false, true, or :development"
            end

            @source_maps = source_maps
            @minify = minify
            @class_pattern = class_pattern
            @tag_pattern = tag_pattern
          end

          def resolve(dependency, context)
            resolve_class_names_runtime(dependency) || resolve_javascript_stylesheet_dependency(dependency, context)
          end

          def load(module_id, _context)
            load_class_names_runtime(module_id)
          end

          def transform(module_id, code, context)
            return super unless module_id.extname == ".css"

            if javascript_stylesheet_module?(module_id)
              javascript_result = transform_css(module_id, code, transform_names: false, context: context)
              css_dependencies = build_dependencies(module_id, javascript_result.dependencies, context)

              return TransformResult.new(
                "Default = nil\n",
                css_dependencies.dependencies,
                nil,
                [],
                [],
                {
                  css_javascript_result: javascript_result,
                  css_javascript_only: true,
                  external_dependencies: css_dependencies.external_dependencies
                }
              )
            end

            scoped_result = transform_css(module_id, code, transform_names: true, context: context)
            css_dependencies = build_dependencies(module_id, scoped_result.dependencies, context)
            compose_dependencies = build_compose_dependencies(module_id, scoped_result)
            styles_dependency = class_names_runtime_dependency(module_id)
            selectors = css_selectors(scoped_result)

            TransformResult.new(
              ruby_module_source(selectors, nil, styles_dependency: styles_dependency),
              [styles_dependency, *css_dependencies.dependencies, *compose_dependencies],
              nil,
              [],
              [],
              {
                css_result: scoped_result,
                css_classes: selectors,
                external_dependencies: css_dependencies.external_dependencies
              }
            )
          end

          def finalize(module_id, result, resolved_dependencies, dependency_records, context)
            css_result = result.metadata[:css_result]
            javascript_only = result.metadata[:css_javascript_only]
            return result unless css_result || javascript_only

            if javascript_only
              javascript_css_edit = finalized_css_edit(
                result.metadata.fetch(:css_javascript_result),
                resolved_dependencies,
                dependency_records,
                result.metadata.fetch(:external_dependencies),
                import_asset_type: :css_javascript_stylesheet
              )
              javascript_asset, javascript_source_map_asset = css_asset_pair(module_id, javascript_css_edit, :css_javascript_stylesheet, {}, context)

              return result.with(
                code: "Default = #{javascript_asset.output_path.inspect}\n",
                assets: [javascript_asset, javascript_source_map_asset, *result.assets].compact,
                metadata: result.metadata.merge(
                  css_javascript_stylesheet_path: javascript_asset.output_path
                )
              )
            end

            css_edit = finalized_css_edit(css_result, resolved_dependencies, dependency_records, result.metadata.fetch(:external_dependencies))
            classes = finalized_css_selectors(css_result, resolved_dependencies, dependency_records)
            asset, source_map_asset = css_asset_pair(module_id, css_edit, :css, {classes: classes}, context)

            result.with(
              code: ruby_module_source(classes, asset.output_path, styles_dependency: result.dependencies.fetch(0)),
              assets: [asset, source_map_asset, *result.assets].compact,
              metadata: result.metadata.merge(
                css_asset_path: asset.output_path,
                css_classes: classes
              )
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

          CssDependencies = ::Data.define(:dependencies, :external_dependencies)
          CssEdit = ::Data.define(:code, :source_map)

          def resolve_javascript_stylesheet_dependency(dependency, context)
            return nil unless javascript_stylesheet_dependency?(dependency)
            return nil if external_url?(dependency.specifier)

            base_module_id =
              if dependency.importer_id
                dependency.importer_id.merge(dependency.specifier)
              else
                ModuleId.new("app:/#{dependency.specifier.to_s.delete_prefix("/")}")
              end
            return nil unless base_module_id.scheme == :app && base_module_id.extname == ".css"

            module_id = ModuleId.new("app:/#{base_module_id.relative_path}", JAVASCRIPT_STYLESHEET_QUERY)
            return nil unless File.file?(context.absolute_path(module_id))

            ResolvedDependency.new(dependency, module_id, {})
          rescue ResolveError
            nil
          end

          def javascript_stylesheet_dependency?(dependency)
            dependency.kind == :javascript_import ||
              (dependency.kind == :css_import && dependency.importer_id&.query == JAVASCRIPT_STYLESHEET_QUERY)
          end

          def javascript_stylesheet_module?(module_id)
            module_id.query == JAVASCRIPT_STYLESHEET_QUERY
          end

          def transform_css(module_id, code, transform_names:, context:)
            Klenod::Plugin::CSS::Transformer.transform(
              module_id.path,
              code,
              minify: minify_enabled?(context),
              transform_names: transform_names,
              class_pattern: @class_pattern,
              tag_pattern: @tag_pattern
            )
          end

          def minify_enabled?(context)
            context.mode == :build || @minify
          end

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

          def build_compose_dependencies(module_id, css_result)
            css_result
              .exports
              .values
              .flat_map(&:composes)
              .grep(Klenod::Plugin::CSS::ComposeDependency)
              .map(&:specifier)
              .uniq
              .each_with_index
              .map do |specifier, index|
                Dependency
                  .create(
                    specifier: specifier,
                    importer_id: module_id,
                    kind: :css_compose
                  )
                  .with(id: "#{module_id}:compose:#{index}")
              end
          end

          def plugin_resolvable_external_import?(dependency, css_dependency, context)
            return false unless css_dependency.is_a?(Klenod::Plugin::CSS::ImportDependency)

            context.resolve_dependency(dependency)
            true
          rescue ResolveError
            false
          end

          def finalized_css_edit(css_result, resolved_dependencies, dependency_records, external_dependencies, import_asset_type: :css)
            replace_dependencies(css_result, resolved_dependencies, dependency_records, external_dependencies, import_asset_type:)
              .then { remove_empty_imports(it) }
          end

          def replace_dependencies(css_result, resolved_dependencies, dependency_records, external_dependencies, import_asset_type:)
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
                    replacement_for_dependency(resolved_dependency, record, import_asset_type:)
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

          def css_asset_pair(module_id, css_edit, type, metadata, context)
            source_map_asset = nil
            css = css_edit.code

            if source_maps_enabled?(context)
              source_map = source_map_for(css_edit.source_map, module_id, context)
              source_map_json = source_map.to_json
              source_map_hash = Hashing.short(source_map_json)
              suffix = (type == :css) ? "" : ".javascript"
              source_map_output_path = "/assets/#{asset_name(module_id)}#{suffix}.#{source_map_hash}.css.map"
              source_map_asset =
                Asset.new(
                  module_id.path,
                  source_map_hash,
                  source_map_output_path,
                  nil,
                  source_map_json,
                  "application/json",
                  {type: (type == :css) ? :css_source_map : :"#{type}_source_map"}
                )
              css = "#{css.chomp}\n/*# sourceMappingURL=#{File.basename(source_map_output_path)} */\n"
            end

            hash = Hashing.short(css)
            suffix = (type == :css) ? "" : ".javascript"
            output_path = "/assets/#{asset_name(module_id)}#{suffix}.#{hash}.css"
            asset =
              Asset.new(
                module_id.path,
                hash,
                output_path,
                nil,
                css,
                "text/css",
                metadata.merge(type: type)
              )

            [asset, source_map_asset]
          end

          def source_map_for(source_map, module_id, context)
            inline_origin = context.virtual_module_metadata(module_id)[:inline_css_origin]
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

          def replacement_for_dependency(resolved_dependency, record, import_asset_type:)
            case resolved_dependency.dependency.kind
            when :css_import
              css_asset = record.assets.find { |asset| asset.metadata[:type] == import_asset_type }
              css_asset ||= record.assets.find { |asset| asset.metadata[:type] == :css } if import_asset_type == :css_javascript_stylesheet
              unless css_asset
                raise UnsupportedFileError, "CSS @import #{resolved_dependency.dependency.specifier.inspect} from #{resolved_dependency.dependency.importer_id} resolved to module #{record.id}, which does not emit a CSS asset"
              end
              return (import_asset_type == :css) ? "" : css_asset.output_path
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

          def finalized_css_selectors(css_result, resolved_dependencies, dependency_records)
            compose_records =
              resolved_dependencies
                .select { it.dependency.kind == :css_compose }
                .to_h do |resolved_dependency|
                  [
                    resolved_dependency.dependency.specifier,
                    dependency_records.fetch(resolved_dependency.dependency.id)
                  ]
                end
            resolved_classes = {}

            resolve_class =
              lambda do |name, resolving|
                return resolved_classes.fetch(name) if resolved_classes.key?(name)
                if resolving.include?(name)
                  raise Error, "Circular local CSS composition involving #{name.inspect}"
                end

                generated_name = css_result.classes.fetch(name)
                export = css_result.exports.fetch(generated_name)
                values = [export.name]

                export.composes.each do |compose|
                  case compose
                  when Klenod::Plugin::CSS::ComposeLocal
                    values.concat(resolve_class.call(compose.name, [*resolving, name]).split)
                  when Klenod::Plugin::CSS::ComposeGlobal
                    values << compose.name
                  when Klenod::Plugin::CSS::ComposeDependency
                    record = compose_records.fetch(compose.specifier)
                    dependency_classes = record.metadata[:css_classes]
                    unless dependency_classes
                      raise UnsupportedFileError,
                        "CSS composes from #{compose.specifier.inspect} resolved to module #{record.id}, which does not export CSS classes"
                    end
                    dependency_class =
                      dependency_classes.fetch(compose.name) do
                        raise UnsupportedFileError,
                          "CSS composes class #{compose.name.inspect} from #{compose.specifier.inspect}, but module #{record.id} does not export it"
                      end
                    values.concat(dependency_class.split)
                  end
                end

                resolved_classes[name] = values.uniq.join(" ")
              end

            css_result.classes.each_key { resolve_class.call(it, []) }
            resolved_classes.merge(css_result.elements.transform_keys { :"__#{it}" })
          end

          def asset_name(module_id)
            module_id.path.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
          end
        end
      end
    end
  end
end
