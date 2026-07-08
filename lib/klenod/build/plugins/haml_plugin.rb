# frozen_string_literal: true

require "syntax_tree"

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
          TemplateNode = Data.define(:type, :line_no, :tag_name, :attributes, :content, :children)

          def compile_template(source, factory:)
            parsed = parse_nodes(source)
            render_nodes = parsed.children.reject { |node| node.type == :ruby_filter }
            ruby_nodes = parsed.children.select { |node| node.type == :ruby_filter }
            ruby_source = compile_ruby_filters(ruby_nodes)
            render_source =
              case render_nodes.length
              when 0 then "nil"
              when 1 then compile_node(render_nodes.fetch(0), factory: factory)
              else "[\n#{indent(render_nodes.map { |node| compile_node(node, factory: factory) }.join(",\n"), 2)}\n]"
              end

            Template.new(ruby_source, render_source)
          end

          def parse_nodes(source)
            root = TemplateNode.new(:root, 0, nil, {}, nil, [])
            stack = [[-1, root]]
            lines = source.lines
            index = 0

            while index < lines.length
              line = lines.fetch(index)
              line_no = index + 1
              if line.strip.empty?
                index += 1
                next
              end

              indent = line[/\A */].length
              stripped = line.strip
              if stripped == ":ruby"
                filter_lines = []
                index += 1

                while index < lines.length
                  child_line = lines.fetch(index)
                  child_indent = child_line[/\A */].length
                  break unless child_line.strip.empty? || child_indent > indent

                  filter_lines << [index + 1, child_line[(indent + 2)..]&.chomp || ""]
                  index += 1
                end

                node = TemplateNode.new(:ruby_filter, line_no, nil, {}, filter_lines, [])
                stack.pop while stack.last.fetch(0) >= indent
                stack.last.fetch(1).children << node
                next
              end

              node = parse_line(stripped, line_no)

              stack.pop while stack.last.fetch(0) >= indent
              stack.last.fetch(1).children << node
              stack << [indent, node]
              index += 1
            end

            root
          end

          def parse_line(line, line_no)
            case line
            when /\A%(?<tag>[A-Za-z][A-Za-z0-9:_-]*)(?<attributes>\(.*\))?=\s*(?<content>.+)\z/
              TemplateNode.new(:dynamic_tag, line_no, $~[:tag], parse_attributes($~[:attributes]), $~[:content], [])
            when /\A%(?<tag>[A-Za-z][A-Za-z0-9:_-]*)(?<attributes>\(.*\))?(?:\s+(?<content>.*))?\z/
              TemplateNode.new(:tag, line_no, $~[:tag], parse_attributes($~[:attributes]), $~[:content], [])
            when /\A=\s*(?<content>.+)\z/
              TemplateNode.new(:expression, line_no, nil, {}, $~[:content], [])
            else
              TemplateNode.new(:text, line_no, nil, {}, line, [])
            end
          end

          def parse_attributes(source)
            return {} unless source

            source
              .delete_prefix("(")
              .delete_suffix(")")
              .split(/\s+/)
              .to_h do |part|
                name, value = part.split("=", 2)
                [name.to_sym, value]
              end
          end

          def compile_node(node, factory:)
            mark = source_mark(node)
            expression =
              case node.type
              when :tag
                compile_tag(node, factory: factory)
              when :dynamic_tag
                compile_dynamic_tag(node, factory: factory)
              when :expression
                "(#{node.content})"
              when :text
                node.content.inspect
              end

            "#{mark}\n#{expression}"
          end

          def compile_dynamic_tag(node, factory:)
            children = ["(#{node.content})"]
            children.concat(node.children.map { |child| compile_node(child, factory: factory) })

            compile_factory_call(node, children, factory: factory)
          end

          def compile_tag(node, factory:)
            children = []
            children << node.content.inspect if node.content
            children.concat(node.children.map { |child| compile_node(child, factory: factory) })

            compile_factory_call(node, children, factory: factory)
          end

          def compile_factory_call(node, children, factory:)
            arguments = [":#{node.tag_name}", *children, *compile_attributes(node)].join(",\n")

            "#{factory}[\n#{indent(arguments, 2)}\n]"
          end

          def compile_attributes(node)
            return [] if node.attributes.empty?

            [
              "#{source_mark(node)},\n{#{node.attributes.map { |name, value| "#{name.inspect} => #{value}" }.join(", ")}}"
            ]
          end

          def compile_ruby_filters(nodes)
            return "" if nodes.empty?

            nodes.map { |node| "begin\n#{indent(compile_ruby_filter(node), 2)}\nend" }.join("\n")
          end

          def compile_ruby_filter(node)
            node
              .content
              .map do |line_no, line|
                "#{source_mark(TemplateNode.new(:ruby_line, line_no, nil, {}, line.strip, []))}\n#{line}"
              end
              .join("\n")
          end

          def source_mark(node)
            "# #{SourceMap::Mark.new(node.line_no, node.content || node.tag_name)}"
          end

          def format_ruby(source)
            SyntaxTree.format(source)
          rescue SyntaxTree::Parser::ParseError
            source
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
