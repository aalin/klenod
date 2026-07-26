# frozen_string_literal: true

require "mayu/css"
require "uri"

require_relative "../asset"
require_relative "../dependency"
require_relative "../errors"
require_relative "../hashing"
require_relative "../plugin"
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

        def finalize(module_id, result, resolved_dependencies, dependency_records, _context)
          css_result = result.metadata[:css_result]
          return result unless css_result

          css = replace_dependencies(
            css_result,
            resolved_dependencies,
            dependency_records,
            result.metadata.fetch(:external_dependencies)
          )
          css = remove_empty_imports(css)
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
            assets: [asset, *result.assets],
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

        def replace_dependencies(css_result, resolved_dependencies, dependency_records, external_dependencies)
          dependencies_by_placeholder =
            resolved_dependencies.filter_map do |resolved_dependency|
              next unless resolved_dependency.dependency.metadata.key?(:placeholder)

              [resolved_dependency.dependency.metadata.fetch(:placeholder), resolved_dependency]
            end.to_h

          css_result.replace_dependencies do |css_dependency|
            next external_dependencies.fetch(css_dependency.placeholder) if external_dependencies.key?(css_dependency.placeholder)

            resolved_dependency = dependencies_by_placeholder.fetch(css_dependency.placeholder)
            record = dependency_records.fetch(resolved_dependency.dependency.id)
            replacement_for_dependency(resolved_dependency, record)
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

        def remove_empty_imports(css)
          css.gsub(/^[ \t]*@import\s+(?:url\(\s*)?["']{2}\s*\)?\s*;\s*\n?/i, "")
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
