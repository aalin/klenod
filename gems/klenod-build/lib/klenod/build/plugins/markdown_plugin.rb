# frozen_string_literal: true

require "klenod/runtime/source_map"
require "date"
require "yaml"

require_relative "../dependency"
require_relative "../module_id"
require_relative "../plugin"
require_relative "../transform_result"
require_relative "../watched_pattern"
require_relative "haml_plugin"
require_relative "markdown_compiler"

module Klenod
  module Build
    module Plugins
      class MarkdownPlugin < Plugin
        DEFAULT_COMPONENT_BASE_CLASS = HamlPlugin::DEFAULT_COMPONENT_BASE_CLASS
        DEFAULT_FACTORY = HamlPlugin::DEFAULT_FACTORY
        COMPONENTS_MODULE_ID = ModuleId.new("markdown-components.rb", nil)
        COMPONENTS_DEPENDENCY_ID_SUFFIX = "markdown_components"

        def initialize(
          component_base_class: DEFAULT_COMPONENT_BASE_CLASS,
          factory: DEFAULT_FACTORY
        )
          @component_base_class = component_base_class
          @factory = factory
        end

        def transform(module_id, code, context)
          return super unless module_id.extname == ".md"

          frontmatter, markdown_source = parse_frontmatter(code)
          builder = HamlPlugin::Transformer::RubyBuilder.new(profiler: context.respond_to?(:profiler) ? context.profiler : nil)
          dependency = markdown_components_dependency(module_id, context)
          components_source = components_source_for(dependency)
          render_source = MarkdownCompiler.new(factory: @factory, components_source: components_source).compile(markdown_source)
          component_class_name = component_class_name(module_id)
          generated =
            builder.component_source(
              component_class_name: component_class_name,
              component_base_class: @component_base_class,
              translations_source: "{}.freeze",
              ruby_source: "",
              render_source: render_source,
              styles_source: "{}.freeze"
            )
          generated = "#{generated}\nDefault.const_set(:Frontmatter, #{frontmatter.inspect}.freeze)\n"

          TransformResult.new(
            generated,
            [dependency].compact,
            Runtime::SourceMap::SourceMap.parse(code, generated),
            [],
            [WatchedPattern.new(module_id, COMPONENTS_MODULE_ID.path, :markdown_components, {})],
            {}
          )
        end

        def import_value(_resolved_dependency, record, context)
          return nil unless record.id.extname == ".md"

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        def runtime_import_value(_resolved_dependency, record, _context)
          return Runtime::DefaultImport.new(:Default) if record.id.extname == ".md"

          super
        end

        private

        def parse_frontmatter(source)
          match = source.match(/\A---[ \t]*\r?\n(?<frontmatter>.*?\r?\n)---[ \t]*(?:\r?\n|\z)/m)
          return [{}, source] unless match

          frontmatter = YAML.safe_load(match[:frontmatter], permitted_classes: [Date, Time, Symbol], aliases: false) || {}
          unless frontmatter.is_a?(Hash)
            raise ArgumentError, "Markdown frontmatter must be a mapping"
          end

          [normalize_frontmatter(frontmatter), source.byteslice(match.end(0)..) || ""]
        end

        def normalize_frontmatter(value)
          case value
          when Hash
            value.transform_values { |item| normalize_frontmatter(item) }
          when Array
            value.map { |item| normalize_frontmatter(item) }
          when Date, Time
            value.iso8601
          else
            value
          end
        end

        def markdown_components_dependency(module_id, context)
          return unless context.absolute_path(COMPONENTS_MODULE_ID).file?

          Dependency
            .create(
              specifier: "/markdown-components",
              importer_id: module_id,
              kind: :markdown_components,
              metadata: {optional: true}
            )
            .with(id: dependency_id(module_id))
        end

        def components_source_for(dependency)
          dependency ? "__klenod_import__(#{dependency.id.inspect})::Default" : "{}"
        end

        def dependency_id(module_id)
          "#{module_id}:#{COMPONENTS_DEPENDENCY_ID_SUFFIX}"
        end

        def component_class_name(module_id)
          parts =
            module_id
              .path
              .delete_suffix(module_id.extname)
              .split(/[^A-Za-z0-9]+/)
              .reject(&:empty?)

          name = parts.map { |part| part[0].upcase + part[1..] }.join
          name.empty? ? "Markdown" : name
        end
      end
    end
  end
end
