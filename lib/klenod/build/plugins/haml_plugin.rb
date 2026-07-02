# frozen_string_literal: true

require_relative "../plugin"
require_relative "../dependency"
require_relative "../module_id"
require_relative "../transform_result"
require_relative "../watched_pattern"

module Klenod
  module Build
    module Plugins
      class HamlPlugin < Plugin
        HamlTransformResult = Data.define(:code, :source_map, :metadata)

        DEFAULT_COMPONENT_BASE_CLASS = "Object"
        DEFAULT_DESCRIPTOR_FACTORY = "Object"

        class DefaultTransformer
          def call(
            source:,
            module_id:,
            component_class_name:,
            component_base_class:,
            descriptor_factory:,
            styles_source:,
            translations_source:
          )
            HamlTransformResult.new(
              <<~RUBY,
                class #{component_class_name} < #{component_base_class}
                  Translations = #{translations_source}
                  DescriptorFactory = #{descriptor_factory}

                  def render
                    DescriptorFactory
                  end
                end

                Default = #{component_class_name}
                Styles = #{styles_source}
                Default.const_set(:Styles, Styles)
                Translations = Default::Translations
              RUBY
              nil,
              {source: source, module_id: module_id}
            )
          end
        end

        def initialize(
          component_base_class: DEFAULT_COMPONENT_BASE_CLASS,
          descriptor_factory: DEFAULT_DESCRIPTOR_FACTORY,
          transformer: DefaultTransformer.new
        )
          @component_base_class = component_base_class
          @descriptor_factory = descriptor_factory
          @transformer = transformer
        end

        def transform(module_id, code, context)
          return super unless module_id.extname == ".haml"

          companion_css = companion_path(module_id, ".css")
          dependencies = []
          styles_source = "{}.freeze"

          if context.absolute_path(companion_css).file?
            dependency =
              Dependency
                .create(
                  specifier: "./#{File.basename(companion_css.path)}",
                  importer_id: module_id,
                  kind: :companion_style,
                  metadata: {optional: true}
                )
                .with(id: "#{module_id}:companion_style")
            dependencies << dependency
            styles_source = "__klenod_import__(#{dependency.id.inspect})"
          end
          translations_source = "{}.freeze"
          component_class_name = component_class_name(module_id)
          haml_result =
            @transformer.call(
              source: code,
              module_id: module_id,
              component_class_name: component_class_name,
              component_base_class: @component_base_class,
              descriptor_factory: @descriptor_factory,
              styles_source: styles_source,
              translations_source: translations_source
            )

          TransformResult.new(
            haml_result.code,
            dependencies,
            haml_result.source_map,
            [],
            companion_patterns(module_id),
            haml_result.metadata
          )
        end

        private

        def component_class_name(module_id)
          basename = File.basename(module_id.path, ".haml")
          classified =
            basename
              .split(/[^A-Za-z0-9]+/)
              .reject(&:empty?)
              .map { |part| part[0].upcase + part[1..] }
              .join

          classified.empty? ? "Component" : classified
        end

        def companion_patterns(module_id)
          base = module_id.path.delete_suffix(".haml")

          [
            WatchedPattern.new(module_id, "#{base}.css", :companion_style, {}),
            WatchedPattern.new(module_id, "#{base}.intl.*.toml", :companion_intl, {})
          ]
        end

        def companion_path(module_id, extname)
          ModuleId.new(module_id.path.delete_suffix(".haml") + extname, nil)
        end
      end
    end
  end
end
