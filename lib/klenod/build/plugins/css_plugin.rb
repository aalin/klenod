# frozen_string_literal: true

require "digest"
require "mayu/css"

require_relative "../asset"
require_relative "../dependency"
require_relative "../plugin"
require_relative "../errors"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class CssPlugin < Plugin
        CSS_DEPENDENCY_TYPES = {
          Mayu::CSS::ImportDependency => :css_import,
          Mayu::CSS::UrlDependency => :asset_url
        }.freeze

        def transform(module_id, code, _context)
          return super unless module_id.extname == ".css"

          result = Mayu::CSS.transform(module_id.path, code, minify: false)
          dependencies =
            result.dependencies.each_with_index.map do |dependency, index|
              Dependency
                .create(
                  specifier: dependency.url,
                  importer_id: module_id,
                  kind: CSS_DEPENDENCY_TYPES.fetch(dependency.class),
                  loc: dependency.loc,
                  metadata: {placeholder: dependency.placeholder}
                )
                .with(id: "#{module_id}:dependency:#{index}")
            end

          TransformResult.new(
            ruby_module_source(result.classes, nil),
            dependencies,
            nil,
            [],
            {
              css_result: result,
              css_classes: result.classes.transform_keys(&:to_s)
            }
          )
        end

        def finalize(module_id, result, resolved_dependencies, dependency_records, _context)
          css_result = result.metadata[:css_result]
          return result unless css_result

          css = replace_dependencies(css_result, resolved_dependencies, dependency_records)
          hash = Digest::SHA256.hexdigest(css)[0, 16]
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
            assets: [asset],
            metadata: result.metadata.merge(css_asset_path: output_path)
          )
        end

        def import_value(_resolved_dependency, record, _context)
          return nil unless record.id.extname == ".css"

          record.assets.first.metadata.fetch(:classes)
        end

        private

        def replace_dependencies(css_result, resolved_dependencies, dependency_records)
          dependencies_by_placeholder =
            resolved_dependencies.to_h do |resolved_dependency|
              [resolved_dependency.dependency.metadata.fetch(:placeholder), resolved_dependency]
            end

          css_result.replace_dependencies do |css_dependency|
            resolved_dependency = dependencies_by_placeholder.fetch(css_dependency.placeholder)
            record = dependency_records.fetch(resolved_dependency.dependency.id)
            record.assets.first&.output_path || record.id.to_s
          end
        end

        def ruby_module_source(classes, asset_path)
          <<~RUBY
            CSS_CLASSES = #{classes.inspect}.freeze
            CSS_ASSET_PATH = #{asset_path.inspect}
          RUBY
        end

        def asset_name(module_id)
          module_id.path.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
        end
      end
    end
  end
end
