# frozen_string_literal: true

require "syntax_tree"
require "syntax_tree/haml"

require_relative "../../source_map"
require_relative "../plugin"
require_relative "../dependency"
require_relative "../errors"
require_relative "../module_id"
require_relative "../transform_result"
require_relative "../watched_pattern"
require_relative "intl_plugin"

module Klenod
  module Build
    module Plugins
      class HamlPlugin < Plugin
        HamlTransformResult = Data.define(:code, :source_map, :metadata)

        DEFAULT_COMPONENT_BASE_CLASS = "Object"
        DEFAULT_FACTORY = "Object"
        IMPORT_RE = /\Aimport\s*\(/

        ImportCall = Data.define(:specifier, :location, :dynamic)

        class DefaultTransformer
          VALID_CONST_PATH = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

          ConstPath = Data.define(:value) do
            def self.parse(value, name:)
              path = value.to_s
              raise ArgumentError, "#{name} must be a Ruby constant path" unless path.match?(VALID_CONST_PATH)

              new(path)
            end

            def to_s
              value
            end
          end

          class RubyBuilder
            def component_source(
              component_class_name:,
              component_base_class:,
              translations_source:,
              ruby_source:,
              render_source:,
              styles_source:
            )
              source =
                <<~RUBY
                  # frozen_string_literal: true

                  KlenodImport = method(:__klenod_import__)

                  class #{component_class_name} < #{component_base_class}
                    def self.module_path
                      __FILE__
                    end

                    Self = self
                    Translations = #{translations_source}

                    def self.__klenod_import__(dependency_id)
                      KlenodImport.call(dependency_id)
                    end

                    def __klenod_import__(dependency_id)
                      self.class.__klenod_import__(dependency_id)
                    end

                  #{indent(ruby_source, 2)}

                    public def render
                  #{indent(render_source, 4)}
                    end
                  end

                  Default = #{component_class_name}
                  Styles = #{styles_source}
                  Default.const_set(:Styles, Styles)
                  Translations = Default::Translations
                RUBY

              format(source)
            end

            def expressions(expressions)
              case expressions.length
              when 0 then "nil"
              when 1 then expressions.fetch(0)
              else "[\n#{indent(expressions.join(",\n"), 2)}\n]"
              end
            end

            def source_mark(line_no, source)
              "# #{SourceMap::Mark.new(line_no, source)}"
            end

            def marked_expression(mark, expression)
              "#{mark}\n#{expression}"
            end

            def factory_call(factory:, tag:, children:, props:, mark:)
              arguments = [tag, *children, keyword_props(props, mark: mark)].compact.join(",\n")

              "#{factory}[\n#{indent(arguments, 2)}\n]"
            end

            def script_block(source, body)
              "#{source}\n#{indent(body, 2)}\nend"
            end

            def silent_script(source)
              "begin\n#{indent(source, 2)}\n  nil\nend"
            end

            def branches(branches)
              branches.map { |source, body| "#{source}\n#{indent(body, 2)}" }.join("\n") + "\nend"
            end

            def ruby_filters(nodes)
              return "" if nodes.empty?

              nodes.map { |node| "begin\n#{indent(node, 2)}\nend" }.join("\n")
            end

            def format(source)
              SyntaxTree.format(source)
            rescue SyntaxTree::Parser::ParseError
              source
            end

            def format_node(node)
              SyntaxTree::Formatter.format(+"", node, 0)
            end

            def indent(value, spaces)
              value.lines.map { |line| "#{" " * spaces}#{line}" }.join
            end

            private

            def keyword_props(props, mark:)
              return nil if props.empty?

              "#{mark},\n**{#{props.map { |name, value| "#{name.inspect} => #{value}" }.join(", ")}}"
            end
          end

          def call(
            source:,
            module_id:,
            component_class_name:,
            component_base_class:,
            factory:,
            styles_source:,
            translations_source:
          )
            component_base_class = ConstPath.parse(component_base_class, name: "component_base_class")
            factory = ConstPath.parse(factory, name: "factory")
            builder = RubyBuilder.new
            template = compile_template(source, factory: factory, builder: builder)
            code =
              builder.component_source(
                component_class_name: component_class_name,
                component_base_class: component_base_class,
                translations_source: translations_source,
                ruby_source: template.ruby_source,
                render_source: template.render_source,
                styles_source: styles_source
              )

            HamlTransformResult.new(
              code,
              SourceMap::SourceMap.parse(source, code),
              {source: source, module_id: module_id}
            )
          end

          private

          Template = Data.define(:ruby_source, :render_source)
          RubyLine = Data.define(:line_no, :source)

          def compile_template(source, factory:, builder:)
            parsed = SyntaxTree::Haml.parse(source)
            render_nodes = parsed.children.reject { |node| ruby_filter?(node) }
            ruby_nodes = parsed.children.select { |node| ruby_filter?(node) }
            ruby_source = compile_ruby_filters(ruby_nodes, builder: builder)
            render_source = compile_nodes(render_nodes, factory: factory, builder: builder)

            Template.new(ruby_source, render_source)
          end

          def compile_nodes(nodes, factory:, builder:)
            builder.expressions(compile_node_expressions(nodes, factory: factory, builder: builder))
          end

          def compile_node_expressions(nodes, factory:, builder:)
            expressions = []
            index = 0

            while index < nodes.length
              node = nodes.fetch(index)

              if script_node?(node) && !continuation?(node)
                group = [node]
                index += 1

                while index < nodes.length && continuation?(nodes.fetch(index))
                  group << nodes.fetch(index)
                  index += 1
                end

                expressions << compile_script_group(group, factory: factory, builder: builder)
              else
                expressions << compile_node(node, factory: factory, builder: builder)
                index += 1
              end
            end

            expressions
          end

          def compile_node(node, factory:, builder:)
            mark = source_mark(node, builder: builder)
            expression =
              case node.type
              when :tag
                compile_tag(node, factory: factory, builder: builder)
              when :plain
                node.value.fetch(:text).inspect
              when :script
                compile_script(node, factory: factory, builder: builder)
              when :silent_script
                compile_silent_script(node, factory: factory, builder: builder)
              when :filter
                compile_filter_node(node)
              end

            builder.marked_expression(mark, expression)
          end

          def compile_script_group(nodes, factory:, builder:)
            return compile_node(nodes.fetch(0), factory: factory, builder: builder) if nodes.length == 1

            compile_branches(
              nodes.map { |node| [script_source(node), node.children] },
              factory: factory,
              builder: builder
            )
          end

          def compile_script(node, factory:, builder:)
            source = script_source(node)
            return "(#{source})" if node.children.empty?

            builder.script_block(source, compile_nodes(node.children, factory: factory, builder: builder))
          end

          def compile_silent_script(node, factory:, builder:)
            source = script_source(node)
            return builder.silent_script(source) if node.children.empty?

            compile_branches(split_silent_script_branches(node), factory: factory, builder: builder)
          end

          def compile_branches(branches, factory:, builder:)
            builder.branches(
              branches.map do |source, children|
                [source, compile_nodes(children, factory: factory, builder: builder)]
              end
            )
          end

          def split_silent_script_branches(node)
            branches = []
            current_source = script_source(node)
            current_children = []

            node.children.each do |child|
              if continuation?(child)
                branches << [current_source, current_children]
                current_source = script_source(child)
                current_children = child.children.dup
              else
                current_children << child
              end
            end

            branches << [current_source, current_children]
          end

          def script_node?(node)
            node.type == :script || node.type == :silent_script
          end

          def script_source(node)
            node.value.fetch(:text).strip
          end

          def continuation?(node)
            script_node?(node) && %w[elsif else when in rescue ensure].include?(node.value.fetch(:keyword))
          end

          def compile_tag(node, factory:, builder:)
            children = []
            value = node.value.fetch(:value)
            if value && !value.empty?
              children << (node.value.fetch(:parse) ? "(#{value})" : value.inspect)
            end
            children.concat(compile_node_expressions(node.children, factory: factory, builder: builder))

            compile_factory_call(node, children, factory: factory, builder: builder)
          end

          def compile_factory_call(node, children, factory:, builder:)
            builder.factory_call(
              factory: factory,
              tag: compile_tag_name(node),
              children: children,
              props: attributes(node, builder: builder),
              mark: source_mark(node, builder: builder)
            )
          end

          def compile_tag_name(node)
            tag_name = node.value.fetch(:name)
            tag_name.match?(/\A[A-Z]/) ? tag_name : ":#{tag_name}"
          end

          def attributes(node, builder:)
            static_attributes(node).merge(dynamic_attributes(node, builder: builder))
          end

          def compile_ruby_filters(nodes, builder:)
            builder.ruby_filters(nodes.map { |node| compile_ruby_filter(node, builder: builder) })
          end

          def compile_ruby_filter(node, builder:)
            node.value.fetch(:text)
              .lines
              .map
              .with_index(node.line + 1) do |line, line_no|
                "#{source_mark(RubyLine.new(line_no, line.strip), builder: builder)}\n#{line.chomp}"
              end
              .join("\n")
          end

          def compile_filter_node(node)
            raise ArgumentError, "Only :ruby Haml filters are supported" unless ruby_filter?(node)

            node.value.fetch(:text).inspect
          end

          def ruby_filter?(node)
            node.type == :filter && node.value.fetch(:name) == "ruby"
          end

          def static_attributes(node)
            node
              .value
              .fetch(:attributes)
              .to_h { |key, value| [key.to_sym, value.inspect] }
          end

          def dynamic_attributes(node, builder:)
            source = node.value.fetch(:dynamic_attributes).old
            return {} unless source

            ast = SyntaxTree.parse(source)
            hash = ast&.statements&.body&.first
            return {} unless hash.is_a?(SyntaxTree::HashLiteral)

            hash.assocs.to_h do |assoc|
              [attribute_key(assoc.key, builder: builder), builder.format_node(assoc.value)]
            end
          end

          def attribute_key(node, builder:)
            case node
            when SyntaxTree::Label
              node.value.delete_suffix(":").to_sym
            else
              builder.format_node(node).to_sym
            end
          end

          def source_mark(node, builder:)
            line_no = node.is_a?(RubyLine) ? node.line_no : node.line

            builder.source_mark(line_no, source_for_mark(node))
          end

          def source_for_mark(node)
            case node
            when RubyLine
              node.source
            else
              case node.type
              when :tag
                node.value.fetch(:value) || node.value.fetch(:name)
              when :plain
                node.value.fetch(:text)
              when :script
                node.value.fetch(:text)
              when :silent_script
                node.value.fetch(:text)
              when :filter
                node.value.fetch(:name).to_s
              end
            end
          end
        end

        def initialize(
          component_base_class: DEFAULT_COMPONENT_BASE_CLASS,
          factory: DEFAULT_FACTORY,
          transformer: DefaultTransformer.new
        )
          @component_base_class = component_base_class
          @factory = factory
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
          translations_source = deep_freeze_source(translations_for(context, module_id))
          component_class_name = component_class_name(module_id)
          haml_result =
            @transformer.call(
              source: code,
              module_id: module_id,
              component_class_name: component_class_name,
              component_base_class: @component_base_class,
              factory: @factory,
              styles_source: styles_source,
              translations_source: translations_source
            )
          import_rewrite = rewrite_imports(module_id, haml_result.code)

          TransformResult.new(
            import_rewrite.code,
            dependencies + import_rewrite.dependencies,
            haml_result.source_map,
            [],
            companion_patterns(module_id),
            haml_result.metadata
          )
        end

        def import_value(_resolved_dependency, record, context)
          return nil unless record.id.extname == ".haml"

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        private

        ImportRewrite = Data.define(:code, :dependencies)

        def rewrite_imports(module_id, code)
          ast = SyntaxTree.parse(code)
          calls = import_calls(ast)

          dependencies =
            calls.each_with_index.map do |call, index|
              if call.dynamic
                raise DynamicImportError, "Only literal import(\"...\") calls are supported in #{module_id}"
              end

              Dependency
                .create(
                  specifier: call.specifier,
                  importer_id: module_id,
                  kind: :haml_import,
                  loc: call.location
                )
                .with(id: "#{module_id}:dependency:#{index}")
            end

          ImportRewrite.new(rewrite_import_calls(code, calls, dependencies), dependencies)
        end

        def import_calls(node)
          calls = []
          walk(node) do |child|
            if child.instance_of?(::SyntaxTree::CallNode)
              next unless child.instance_variable_get(:@receiver).nil?
              next unless child.instance_variable_get(:@message)&.value == "import"

              calls << build_import_call(child)
            elsif child.instance_of?(::SyntaxTree::Command)
              next unless child.instance_variable_get(:@message)&.value == "import"

              calls << build_import_command(child)
            end
          end
          calls
        end

        def build_import_call(node)
          arguments = node.instance_variable_get(:@arguments)
          parts = arguments&.instance_variable_get(:@arguments)&.instance_variable_get(:@parts) || []
          build_import_from_parts(node, parts)
        end

        def build_import_command(node)
          arguments = node.instance_variable_get(:@arguments)
          parts = arguments&.instance_variable_get(:@parts) || []
          build_import_from_parts(node, parts)
        end

        def build_import_from_parts(node, parts)
          first = unwrap_paren(parts.first)
          string_parts = first&.instance_variable_get(:@parts)
          literal =
            (parts.length == 1) &&
            first&.class&.name == "SyntaxTree::StringLiteral" &&
            string_parts&.length == 1 &&
            string_parts.first.instance_of?(::SyntaxTree::TStringContent)

          ImportCall.new(
            literal ? string_parts.first.value : nil,
            node.instance_variable_get(:@location),
            !literal
          )
        end

        def unwrap_paren(node)
          return node unless node.instance_of?(::SyntaxTree::Paren)

          statements = node.instance_variable_get(:@contents)
          body = statements&.instance_variable_get(:@body) || []
          (body.length == 1) ? body.first : node
        end

        def rewrite_import_calls(code, calls, dependencies)
          calls
            .zip(dependencies)
            .reverse_each
            .each_with_object(code.dup) do |(call, dependency), rewritten|
              next rewritten if call.dynamic

              location = call.location
              original = code[location.start_char...location.end_char]
              unless original.match?(IMPORT_RE)
                raise DynamicImportError, "Could not safely rewrite import at #{location.start_line}:#{location.start_column}"
              end

              rewritten[location.start_char...location.end_char] =
                "__klenod_import__(#{dependency.id.inspect})"
            end
        end

        def walk(value, &block)
          yield value

          case value
          when Array
            value.each { |item| walk(item, &block) }
          else
            return unless value.respond_to?(:instance_variables)

            value.instance_variables.each do |ivar|
              walk(value.instance_variable_get(ivar), &block)
            end
          end
        end

        def translations_for(context, module_id)
          intl_plugin = context.plugins.find { |plugin| plugin.respond_to?(:translations_for) }
          intl_plugin ? intl_plugin.translations_for(context, module_id) : {}
        end

        def deep_freeze_source(value)
          case value
          when Hash
            "{#{value.map { |key, child| "#{key.inspect} => #{deep_freeze_source(child)}" }.join(", ")}}.freeze"
          when Array
            "[#{value.map { |child| deep_freeze_source(child) }.join(", ")}].freeze"
          else
            value.inspect
          end
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
