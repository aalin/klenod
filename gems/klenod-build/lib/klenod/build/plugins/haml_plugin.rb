# frozen_string_literal: true

require "syntax_tree"

require_relative "../plugin"
require_relative "../dependency"
require_relative "../module_id"
require_relative "../ruby_import_rewriter"
require_relative "../transform_result"
require_relative "../watched_pattern"
require_relative "intl_plugin"
require_relative "markdown_compiler"
require_relative "class_names_runtime"
require_relative "component_defaults"
require_relative "haml_plugin/errors"
require_relative "haml_plugin/parser"
require_relative "haml_plugin/transformer"
require_relative "haml_plugin/helper_source"
require_relative "haml_plugin/companions"

module Klenod
  module Build
    module Plugins
      module HamlPlugin
        def self.new(...)
          Plugin.new(...)
        end

        DEFAULT_COMPONENT_BASE_CLASS = ComponentDefaults::DEFAULT_COMPONENT_BASE_CLASS
        DEFAULT_FACTORY = ComponentDefaults::DEFAULT_FACTORY
        HAML_HELPER_SPECIFIER = "virtual:klenod/haml_helper"
        HAML_HELPER_MODULE_ID = ModuleId.new("#{HAML_HELPER_SPECIFIER}.rb", nil)
        STATIC_CLASS_SOURCE_PATTERN = /^[ \t]*(?:%[-:\w]+)?(?:#[\w-]+)?\.[\w-]|[({][^)}\n]*\bclass\s*=/m
      end

      module HamlPlugin
        class Plugin < Klenod::Build::Plugin
          ParseError = HamlPlugin::ParseError
          RubyParseError = HamlPlugin::RubyParseError
          HamlTransformResult = HamlPlugin::HamlTransformResult
          Transformer = HamlPlugin::Transformer
          ParserWithMetadata = HamlPlugin::ParserWithMetadata

          DEFAULT_COMPONENT_BASE_CLASS = HamlPlugin::DEFAULT_COMPONENT_BASE_CLASS
          DEFAULT_FACTORY = HamlPlugin::DEFAULT_FACTORY
          HAML_HELPER_SPECIFIER = HamlPlugin::HAML_HELPER_SPECIFIER
          HAML_HELPER_MODULE_ID = HamlPlugin::HAML_HELPER_MODULE_ID
          STATIC_CLASS_SOURCE_PATTERN = HamlPlugin::STATIC_CLASS_SOURCE_PATTERN

          def self.parse_haml(...)
            HamlPlugin.parse_haml(...)
          end

          include ClassNamesRuntime
          include HelperSource
          include Companions

          def initialize(
            component_base_class: DEFAULT_COMPONENT_BASE_CLASS,
            factory: DEFAULT_FACTORY,
            variables: nil,
            i18n_class: nil,
            i18n_constant: nil,
            cache_static_subtrees: false
          )
            @component_base_class = component_base_class
            @factory = factory
            @variables = validate_variables(variables)
            @i18n_class, @i18n_constant = validate_i18n_options(i18n_class, i18n_constant)
            @cache_static_subtrees = cache_static_subtrees
            @transformer = Transformer.new
          end

          def resolve(dependency, _context)
            styles_dependency = resolve_class_names_runtime(dependency)
            return styles_dependency if styles_dependency

            return nil unless dependency.specifier == HAML_HELPER_SPECIFIER

            ResolvedDependency.new(dependency, HAML_HELPER_MODULE_ID, {virtual: true})
          end

          def load(module_id, _context)
            styles_load = load_class_names_runtime(module_id)
            return styles_load if styles_load

            return nil unless module_id.scheme == :virtual && module_id == HAML_HELPER_MODULE_ID

            LoadResult.new(haml_helper_source, nil, TransformResult.new(haml_helper_source, [], nil, [], [], {}))
          end

          def transform(module_id, code, context)
            return super unless module_id.extname == ".haml"

            companion_css = companion_path(module_id, ".css")
            dependencies = []
            style_dependencies = []
            import_dependencies = []
            watched_patterns = []
            markdown_filters = markdown_filter_nodes(code, module_id: module_id)
            builder = Transformer::RubyBuilder.new(profiler: context.profiler)
            context.unregister_virtual_modules(module_id)

            if context.absolute_path(companion_css).file? && css_plugin_available?(context)
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
              style_dependencies << dependency
            end
            markdown_components_dependency = nil
            if markdown_filters.any?
              markdown_components_id = ModuleId.new("markdown-components.rb", nil)
              watched_patterns << WatchedPattern.new(module_id, markdown_components_id.path, :markdown_components, {})
              if context.absolute_path(markdown_components_id).file?
                markdown_components_dependency =
                  Dependency
                    .create(
                      specifier: "/markdown-components",
                      importer_id: module_id,
                      kind: :markdown_components,
                      metadata: {optional: true}
                    )
                    .with(id: "#{module_id}:markdown_components")
                dependencies << markdown_components_dependency
              end
            end
            inline_css_sources(code, module_id: module_id).each_with_index do |source, index|
              virtual_module_id = ModuleId.new("#{module_id.path}.inline.#{index}.css", nil)
              context.register_virtual_module(
                virtual_module_id,
                source.text,
                owner_id: module_id,
                metadata: {
                  inline_css_origin: {
                    module_id: module_id,
                    source: code,
                    line_offset: source.line_offset,
                    column_offset: source.column_offset
                  }
                }
              )
              dependency =
                Dependency
                  .create(
                    specifier: virtual_module_id.to_s,
                    importer_id: module_id,
                    kind: :inline_style,
                    metadata: {virtual_module_id: virtual_module_id}
                  )
                  .with(id: "#{module_id}:inline_style:#{index}")
              dependencies << dependency
              style_dependencies << dependency
            end
            class_names_runtime_dependency = class_names_runtime_dependency(module_id)
            dependencies << class_names_runtime_dependency
            styles_source = styles_source_for(builder, style_dependencies, class_names_runtime_dependency: class_names_runtime_dependency)
            haml_helper_needed = @cache_static_subtrees || haml_helper_needed?(code, styleable: !style_dependencies.empty?)
            haml_helper_dependency = haml_helper_dependency(module_id) if haml_helper_needed
            dependencies << haml_helper_dependency if haml_helper_dependency
            translations_source = builder.frozen_literal(translations_for(context, module_id)).source
            component_class_name = component_class_name(module_id)
            import_rewriter =
              lambda do |source, source_line_offset: 0, source_column_offset: 0|
                result =
                  RubyImportRewriter
                    .new(
                      module_id: module_id,
                      kind: :haml_import,
                      source_dir: context.source_dir,
                      profiler: context.profiler,
                      dependency_id_offset: import_dependencies.length,
                      source_line_offset: source_line_offset,
                      source_column_offset: source_column_offset
                    )
                    .rewrite(source)
                import_dependencies.concat(result.dependencies)
                watched_patterns.concat(result.watched_patterns)
                result.code
              end
            haml_result =
              @transformer.call(
                source: code,
                module_id: module_id,
                component_class_name: component_class_name,
                component_base_class: @component_base_class,
                factory: @factory,
                styles_source: styles_source,
                translations_source: translations_source,
                i18n_source: i18n_source_for(builder),
                haml_helper_source: haml_helper_dependency && builder.constant_assignment("HamlHelper", "#{builder.import_call(haml_helper_dependency.id).source}::Default"),
                styleable: !style_dependencies.empty?,
                profiler: context.profiler,
                import_rewriter: import_rewriter,
                markdown_components_source: markdown_components_dependency ? "__klenod_import__(#{markdown_components_dependency.id.inspect})::Default" : "{}",
                variables: @variables,
                cache_static_subtrees: @cache_static_subtrees
              )
            import_rewrite =
              if !haml_result.code.include?("import(") && !haml_result.code.include?("lazy_import(") && !haml_result.code.include?("import_glob(")
                RubyImportRewriter::Result.new(haml_result.code, [], [])
              else
                context.profiler.measure(:haml_import_rewrite, module_id: module_id.to_s) do
                  RubyImportRewriter
                    .new(
                      module_id: module_id,
                      kind: :haml_import,
                      source_dir: context.source_dir,
                      profiler: context.profiler,
                      dependency_id_offset: import_dependencies.length
                    )
                    .rewrite(haml_result.code)
                end
              end

            watched_patterns.concat(import_rewrite.watched_patterns)

            TransformResult.new(
              import_rewrite.code,
              dependencies + import_dependencies + import_rewrite.dependencies,
              haml_result.source_map,
              [],
              companion_patterns(module_id) + watched_patterns,
              haml_result.metadata
            )
          end

          def import_value(resolved_dependency, record, context)
            styles_import = class_names_runtime_import_value(resolved_dependency, record, context)
            return styles_import if styles_import
            return nil unless record.id.extname == ".haml"

            context.mods.fetch(record.id).const_get(:Exports)::Default
          end

          def runtime_import_value(resolved_dependency, record, _context)
            styles_import = class_names_runtime_runtime_import_value(resolved_dependency, record)
            return styles_import if styles_import
            return Runtime::DefaultImport.new(:Default) if record.id.extname == ".haml"

            super
          end

          def invalidate_module_ids(paths, context)
            paths
              .filter_map { |path| companion_owner_module_id(path, context) }
              .uniq
          end

          private

          InlineCssSource = Data.define(:text, :line_offset, :column_offset)

          VARIABLE_KINDS = %i[global class instance].freeze

          def validate_variables(variables)
            return {}.freeze if variables.nil?
            raise ArgumentError, "variables must be a Hash" unless variables.is_a?(Hash)

            unknown_kinds = variables.keys - VARIABLE_KINDS
            unless unknown_kinds.empty?
              raise ArgumentError, "variables contains unknown kinds: #{unknown_kinds.map(&:inspect).join(", ")}"
            end

            variables.to_h { |kind, source| [kind, validate_variable_receiver(kind, source)] }.freeze
          end

          def validate_variable_receiver(kind, source)
            raise ArgumentError, "variables[#{kind.inspect}] must be a Ruby expression String" unless source.is_a?(String)

            parsed = SyntaxTree.parse(source)&.statements&.body
            raise ArgumentError, "variables[#{kind.inspect}] must be a Ruby expression" unless parsed&.length == 1
            SyntaxTree.parse("(#{source})[:__klenod_variable__]")

            source
          rescue SyntaxTree::Parser::ParseError
            raise ArgumentError, "variables[#{kind.inspect}] must be a Ruby expression"
          end

          def validate_i18n_options(i18n_class, i18n_constant)
            return [nil, nil] if i18n_class.nil? && i18n_constant.nil?
            raise ArgumentError, "i18n_class must be configured when i18n_constant is configured" if i18n_class.nil?

            i18n_constant = (i18n_constant || "I18n").to_s
            raise ArgumentError, "i18n_constant must be a Ruby constant name" unless i18n_constant.match?(/\A[A-Z]\w*\z/)

            [
              Transformer::ConstPath.parse(i18n_class, name: "i18n_class").to_s,
              i18n_constant
            ]
          end

          def i18n_source_for(builder)
            return nil unless @i18n_class

            builder.constant_assignment(@i18n_constant, "#{@i18n_class}.new(self)")
          end

          def translations_for(context, module_id)
            intl_plugin = context.plugins.find { |plugin| plugin.respond_to?(:translations_for) }
            intl_plugin ? intl_plugin.translations_for(context, module_id) : {}
          end

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

          def inline_css_sources(source, module_id: nil)
            lines = source.lines
            filter_nodes(source, "css", module_id: module_id).map do |node|
              text = node.value.fetch(:text)
              line_offset = node.line
              column_offset = inline_filter_column_offset(lines, line_offset, text)

              InlineCssSource.new(text, line_offset, column_offset)
            end
          end

          def inline_filter_column_offset(lines, line_offset, text)
            text.lines.each_with_index do |text_line, index|
              next if text_line.strip.empty?

              source_line = lines.fetch(line_offset + index, "")
              return source_line.length - source_line.lstrip.length
            end

            0
          end

          def markdown_filter_nodes(source, module_id: nil)
            return [] unless source.include?(":markdown")

            filter_nodes(source, "markdown", module_id: module_id)
          end

          def filter_nodes(source, name, module_id: nil)
            nodes = []
            queue = HamlPlugin.parse_haml(source, module_id: module_id).children.dup

            until queue.empty?
              node = queue.shift
              nodes << node if node.type == :filter && node.value.fetch(:name) == name
              queue.concat(node.children)
            end

            nodes
          end

          def styles_source_for(builder, dependencies, class_names_runtime_dependency:)
            class_names_runtime = builder.import_call(class_names_runtime_dependency.id).source
            imports = dependencies.map { |dependency| builder.import_call(dependency.id) }
            return "#{class_names_runtime}.new({}.freeze)" if imports.empty?
            return imports.fetch(0).source if imports.length == 1

            builder
              .expression(
                "#{class_names_runtime}.merge(#{imports.map(&:source).join(", ")})"
              )
              .source
          end

          def css_plugin_available?(context)
            context.plugins.any? { it.respond_to?(:javascript_stylesheet_module?, true) }
          end
        end
      end
    end
  end
end
