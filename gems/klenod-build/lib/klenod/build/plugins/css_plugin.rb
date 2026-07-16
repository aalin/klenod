# frozen_string_literal: true

require "mayu/css"
require "uri"

require_relative "../asset"
require_relative "../dependency"
require_relative "../errors"
require_relative "../hashing"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class CssPlugin < Plugin
        CSS_DEPENDENCY_TYPES = {
          Mayu::CSS::ImportDependency => :css_import,
          Mayu::CSS::UrlDependency => :asset_url
        }.freeze

        def transform(module_id, code, context)
          return super unless module_id.extname == ".css"

          result = Mayu::CSS.transform(module_id.path, code, minify: false)
          css_dependencies = build_dependencies(module_id, result.dependencies, context)

          TransformResult.new(
            ruby_module_source(css_selectors(result), nil),
            css_dependencies.dependencies,
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
            code: ruby_module_source(result.metadata[:css_classes], output_path),
            assets: [asset, *result.assets],
            metadata: result.metadata.merge(css_asset_path: output_path)
          )
        end

        def import_value(_resolved_dependency, record, _context)
          return nil unless record.id.extname == ".css"

          record.assets.first.metadata.fetch(:classes)
        end

        alias_method :runtime_import_value, :import_value

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
            resolved_dependencies.to_h do |resolved_dependency|
              [resolved_dependency.dependency.metadata.fetch(:placeholder), resolved_dependency]
            end

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

        def ruby_module_source(classes, asset_path)
          <<~RUBY
            CSS_CLASSES = #{classes.inspect}.freeze
            CSS_ASSET_PATH = #{asset_path.inspect}
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
