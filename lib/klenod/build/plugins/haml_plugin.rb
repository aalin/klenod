# frozen_string_literal: true

require "syntax_tree"
require "syntax_tree/haml"

require_relative "../../source_map"
require_relative "../plugin"
require_relative "../dependency"
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
            template = compile_template(source, factory: factory)
            code =
              format_ruby(
                <<~RUBY
                  # frozen_string_literal: true

                  class #{component_class_name} < #{component_base_class}
                    def self.module_path
                      __FILE__
                    end

                    Self = self
                    Translations = #{translations_source}

                  #{indent(template.ruby_source, 2)}

                    public def render
                  #{indent(template.render_source, 4)}
                    end
                  end

                  Default = #{component_class_name}
                  Styles = #{styles_source}
                  Default.const_set(:Styles, Styles)
                  Translations = Default::Translations
              RUBY
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

          def compile_template(source, factory:)
            parsed = SyntaxTree::Haml.parse(source)
            render_nodes = parsed.children.reject { |node| ruby_filter?(node) }
            ruby_nodes = parsed.children.select { |node| ruby_filter?(node) }
            ruby_source = compile_ruby_filters(ruby_nodes)
            render_source = compile_nodes(render_nodes, factory: factory)

            Template.new(ruby_source, render_source)
          end

          def compile_nodes(nodes, factory:)
            expressions = compile_node_expressions(nodes, factory: factory)

            case expressions.length
            when 0 then "nil"
            when 1 then expressions.fetch(0)
            else "[\n#{indent(expressions.join(",\n"), 2)}\n]"
            end
          end

          def compile_node_expressions(nodes, factory:)
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

                expressions << compile_script_group(group, factory: factory)
              else
                expressions << compile_node(node, factory: factory)
                index += 1
              end
            end

            expressions
          end

          def compile_node(node, factory:)
            mark = source_mark(node)
            expression =
              case node.type
              when :tag
                compile_tag(node, factory: factory)
              when :plain
                node.value.fetch(:text).inspect
              when :script
                compile_script(node, factory: factory)
              when :silent_script
                compile_silent_script(node, factory: factory)
              when :filter
                compile_filter_node(node)
              end

            "#{mark}\n#{expression}"
          end

          def compile_script_group(nodes, factory:)
            return compile_node(nodes.fetch(0), factory: factory) if nodes.length == 1

            compile_branches(
              nodes.map { |node| [script_source(node), node.children] },
              factory: factory
            )
          end

          def compile_script(node, factory:)
            source = script_source(node)
            return "(#{source})" if node.children.empty?

            "#{source}\n#{indent(compile_nodes(node.children, factory: factory), 2)}\nend"
          end

          def compile_silent_script(node, factory:)
            source = script_source(node)
            return "begin\n#{indent(source, 2)}\n  nil\nend" if node.children.empty?

            compile_branches(split_silent_script_branches(node), factory: factory)
          end

          def compile_branches(branches, factory:)
            branches
              .map
              .with_index do |(source, children), _index|
                body = compile_nodes(children, factory: factory)

                "#{source}\n#{indent(body, 2)}"
              end
              .join("\n") + "\nend"
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

          def compile_tag(node, factory:)
            children = []
            value = node.value.fetch(:value)
            if value && !value.empty?
              children << (node.value.fetch(:parse) ? "(#{value})" : value.inspect)
            end
            children.concat(compile_node_expressions(node.children, factory: factory))

            compile_factory_call(node, children, factory: factory)
          end

          def compile_factory_call(node, children, factory:)
            arguments = [":#{node.value.fetch(:name)}", *children, *compile_attributes(node)].join(",\n")

            "#{factory}[\n#{indent(arguments, 2)}\n]"
          end

          def compile_attributes(node)
            attributes = static_attributes(node).merge(dynamic_attributes(node))
            return [] if attributes.empty?

            [
              "#{source_mark(node)},\n{#{attributes.map { |name, value| "#{name.inspect} => #{value}" }.join(", ")}}"
            ]
          end

          def compile_ruby_filters(nodes)
            return "" if nodes.empty?

            nodes.map { |node| "begin\n#{indent(compile_ruby_filter(node), 2)}\nend" }.join("\n")
          end

          def compile_ruby_filter(node)
            node.value.fetch(:text)
              .lines
              .map
              .with_index(node.line + 1) do |line, line_no|
                "#{source_mark(RubyLine.new(line_no, line.strip))}\n#{line.chomp}"
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

          def dynamic_attributes(node)
            source = node.value.fetch(:dynamic_attributes).old
            return {} unless source

            ast = SyntaxTree.parse(source)
            hash = ast&.statements&.body&.first
            return {} unless hash.is_a?(SyntaxTree::HashLiteral)

            hash.assocs.to_h do |assoc|
              [attribute_key(assoc.key), format_node(assoc.value)]
            end
          end

          def attribute_key(node)
            case node
            when SyntaxTree::Label
              node.value.delete_suffix(":").to_sym
            else
              format_node(node).to_sym
            end
          end

          def source_mark(node)
            line_no = node.is_a?(RubyLine) ? node.line_no : node.line

            "# #{SourceMap::Mark.new(line_no, source_for_mark(node))}"
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

          def format_ruby(source)
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
