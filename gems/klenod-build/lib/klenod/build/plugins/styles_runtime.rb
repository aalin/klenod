# frozen_string_literal: true

require_relative "../dependency"
require_relative "../load_result"
require_relative "../module_id"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module StylesRuntime
        STYLES_SPECIFIER = "virtual:klenod/styles"
        STYLES_MODULE_ID = ModuleId.new("virtual:klenod/styles.rb", nil)

        def resolve_styles_runtime(dependency)
          return nil unless dependency.specifier == STYLES_SPECIFIER

          ResolvedDependency.new(dependency, STYLES_MODULE_ID, {virtual: true})
        end

        def load_styles_runtime(module_id)
          return nil unless module_id.scheme == :virtual && module_id == STYLES_MODULE_ID

          source = styles_runtime_source
          LoadResult.new(source, nil, TransformResult.new(source, [], nil, [], [], {}))
        end

        def styles_runtime_dependency(module_id)
          Dependency
            .create(
              specifier: STYLES_SPECIFIER,
              importer_id: module_id,
              kind: :styles_runtime
            )
            .with(id: STYLES_SPECIFIER)
        end

        def styles_runtime_import_value(resolved_dependency, record, context)
          return nil unless resolved_dependency.dependency.kind == :styles_runtime

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        def styles_runtime_runtime_import_value(resolved_dependency, _record)
          return nil unless resolved_dependency.dependency.kind == :styles_runtime

          Runtime::DefaultImport.new(:Default)
        end

        def styles_runtime_source
          <<~RUBY
            # frozen_string_literal: true

            class Styles
              def self.merge(*sources)
                classes = sources.each_with_object({}) do |source, result|
                  source.each_pair do |name, class_name|
                    result[name] = [result[name], class_name].compact.join(" ")
                  end
                end

                new(classes.freeze)
              end

              def initialize(classes)
                @classes = classes
              end

              def [](first = nil, *rest)
                return @classes[first] if rest.empty? && first.is_a?(Symbol)

                class_name(first, *rest)
              end

              def fetch(...)
                @classes.fetch(...)
              end

              def key?(...)
                @classes.key?(...)
              end

              def keys
                @classes.keys
              end

              def each_pair(...)
                @classes.each_pair(...)
              end

              def class_name(*values)
                classes = []
                values.each { |value| collect_class_names(classes, value) }
                return nil if classes.empty?

                classes.join(" ")
              end

              private

              def collect_class_names(classes, value)
                case value
                when nil, false
                  nil
                when Symbol
                  collect_class_names(classes, @classes[value])
                when String
                  value.split.each { |class_name| classes << class_name }
                when Array
                  value.each { |item| collect_class_names(classes, item) }
                when Hash
                  value.each { |class_name, enabled| collect_class_names(classes, class_name) if enabled }
                else
                  value.to_s.split.each { |class_name| classes << class_name }
                end
              end
            end

            Default = Styles
          RUBY
        end
      end
    end
  end
end
